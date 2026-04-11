// Edge runtime for streaming support
export const config = { runtime: 'edge' };

// Free tier: 100K tokens per day
const FREE_DAILY_TOKEN_LIMIT = 100_000;

export default async function handler(req) {
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      },
    });
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405 });
  }

  // Validate JWT
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
  }
  const jwt = authHeader.slice(7);

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;

  // Verify JWT with Supabase
  let user;
  try {
    const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: {
        'apikey': SUPABASE_KEY,
        'Authorization': `Bearer ${jwt}`,
      },
    });
    if (!userRes.ok) {
      return new Response(JSON.stringify({ error: 'Invalid or expired token. Sign in again.' }), { status: 401 });
    }
    user = await userRes.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Auth verification failed' }), { status: 401 });
  }

  // Check daily usage limit (free tier)
  try {
    const today = new Date();
    today.setHours(0, 0, 0, 0);

    const usageRes = await fetch(
      `${SUPABASE_URL}/rest/v1/usage_logs?user_id=eq.${user.id}&created_at=gte.${today.toISOString()}&select=input_tokens,output_tokens`,
      {
        headers: {
          'apikey': SUPABASE_KEY,
          'Authorization': `Bearer ${SUPABASE_KEY}`,
        },
      }
    );
    const logs = await usageRes.json();

    let totalTokens = 0;
    for (const log of (logs || [])) {
      totalTokens += (log.input_tokens || 0) + (log.output_tokens || 0);
    }

    if (totalTokens >= FREE_DAILY_TOKEN_LIMIT) {
      return new Response(JSON.stringify({
        error: 'Daily free limit reached. Resets tomorrow. Need more? Email hello@artiphik.com',
        usage_limit_reached: true,
        total_tokens_today: totalTokens,
        daily_limit: FREE_DAILY_TOKEN_LIMIT,
      }), { status: 429 });
    }
  } catch {
    // If usage check fails, allow the request (fail open for now)
    console.error('Usage check failed, allowing request');
  }

  // Parse request
  const body = await req.json();
  const { model, system, messages, stream } = body;

  if (!model || !messages) {
    return new Response(JSON.stringify({ error: 'model and messages required' }), { status: 400 });
  }

  // Determine provider from model name
  let providerResponse;
  try {
    if (model.startsWith('claude-') || model.startsWith('claude_')) {
      providerResponse = await forwardToAnthropic(model, system, messages, stream);
    } else if (model.startsWith('gpt-')) {
      providerResponse = await forwardToOpenAI(model, system, messages, stream);
    } else if (model.startsWith('gemini-')) {
      providerResponse = await forwardToGemini(model, system, messages, stream);
    } else {
      return new Response(JSON.stringify({ error: `Unknown model: ${model}` }), { status: 400 });
    }
  } catch (err) {
    return new Response(JSON.stringify({ error: `Provider error: ${err.message}` }), { status: 502 });
  }

  // Log usage asynchronously (don't block the stream)
  const userId = user.id;
  logUsage(userId, model, body, SUPABASE_URL, SUPABASE_KEY).catch(() => {});

  // Stream the provider response back to the client
  return new Response(providerResponse.body, {
    status: providerResponse.status,
    headers: {
      'Content-Type': providerResponse.headers.get('Content-Type') || 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Access-Control-Allow-Origin': '*',
    },
  });
}

async function forwardToAnthropic(model, system, messages, stream) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) throw new Error('Anthropic API key not configured on server');

  // Convert messages: strip image wrapper if needed
  const cleanMessages = messages.map(m => {
    if (Array.isArray(m.content)) {
      const parts = m.content.map(p => {
        if (p.type === 'image' && p.data) {
          return { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: p.data } };
        }
        return p;
      });
      return { ...m, content: parts };
    }
    return m;
  });

  const body = { model, messages: cleanMessages, stream: stream !== false, max_tokens: 1024 };
  if (system) body.system = system;

  return fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  });
}

async function forwardToOpenAI(model, system, messages, stream) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) throw new Error('OpenAI API key not configured on server');

  // Convert to OpenAI format
  const openaiMessages = [];
  if (system) openaiMessages.push({ role: 'system', content: system });

  for (const m of messages) {
    if (Array.isArray(m.content)) {
      const parts = m.content.map(p => {
        if (p.type === 'image' && p.data) {
          return { type: 'image_url', image_url: { url: `data:image/jpeg;base64,${p.data}` } };
        }
        if (p.type === 'text') return { type: 'text', text: p.text };
        return p;
      });
      openaiMessages.push({ role: m.role, content: parts });
    } else {
      openaiMessages.push(m);
    }
  }

  return fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ model, messages: openaiMessages, stream: stream !== false }),
  });
}

async function forwardToGemini(model, system, messages, stream) {
  const apiKey = process.env.GOOGLE_AI_API_KEY;
  if (!apiKey) throw new Error('Google AI API key not configured on server');

  // Convert to Gemini format
  const contents = messages.map(m => {
    const role = m.role === 'assistant' ? 'model' : 'user';
    if (Array.isArray(m.content)) {
      const parts = m.content.map(p => {
        if (p.type === 'image' && p.data) {
          return { inline_data: { mime_type: 'image/jpeg', data: p.data } };
        }
        if (p.type === 'text') return { text: p.text };
        return { text: String(p) };
      });
      return { role, parts };
    }
    return { role, parts: [{ text: typeof m.content === 'string' ? m.content : JSON.stringify(m.content) }] };
  });

  const body = { contents, generationConfig: { maxOutputTokens: 1024 } };
  if (system) body.systemInstruction = { parts: [{ text: system }] };

  const base = `https://generativelanguage.googleapis.com/v1beta/models/${model}`;
  const streaming = stream !== false;
  const url = streaming
    ? `${base}:streamGenerateContent?alt=sse&key=${apiKey}`
    : `${base}:generateContent?key=${apiKey}`;

  return fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function logUsage(userId, model, requestBody, supabaseUrl, supabaseKey) {
  // Estimate input tokens (~4 chars per token)
  const messageText = JSON.stringify(requestBody.messages || []);
  const systemText = requestBody.system || '';
  const estimatedInputTokens = Math.ceil((messageText.length + systemText.length) / 4);
  // Estimate output tokens (will be roughly similar to a short response)
  const estimatedOutputTokens = 250;

  await fetch(`${supabaseUrl}/rest/v1/usage_logs`, {
    method: 'POST',
    headers: {
      'apikey': supabaseKey,
      'Authorization': `Bearer ${supabaseKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      user_id: userId,
      model,
      provider: model.startsWith('claude') ? 'claude' : model.startsWith('gpt') ? 'openai' : 'gemini',
      input_tokens: estimatedInputTokens,
      output_tokens: estimatedOutputTokens,
      cost_cents: 0,
    }),
  });
}
