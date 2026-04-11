export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Not authenticated' });
  }
  const jwt = authHeader.slice(7);

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;

  // Verify user
  let user;
  try {
    const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { 'apikey': SUPABASE_KEY, 'Authorization': `Bearer ${jwt}` },
    });
    if (!userRes.ok) return res.status(401).json({ error: 'Invalid token' });
    user = await userRes.json();
  } catch {
    return res.status(401).json({ error: 'Auth failed' });
  }

  try {
    // Get today's usage (daily reset for free tier)
    const today = new Date();
    today.setHours(0, 0, 0, 0);

    const usageRes = await fetch(
      `${SUPABASE_URL}/rest/v1/usage_logs?user_id=eq.${user.id}&created_at=gte.${today.toISOString()}&select=provider,model,input_tokens,output_tokens,cost_cents`,
      { headers: { 'apikey': SUPABASE_KEY, 'Authorization': `Bearer ${SUPABASE_KEY}` } }
    );
    const logs = await usageRes.json();

    // Aggregate
    let totalRequests = 0;
    let totalInputTokens = 0;
    let totalOutputTokens = 0;
    let totalCostCents = 0;
    const byProvider = {};

    for (const log of (logs || [])) {
      totalRequests++;
      totalInputTokens += log.input_tokens || 0;
      totalOutputTokens += log.output_tokens || 0;
      totalCostCents += log.cost_cents || 0;

      const p = log.provider || 'unknown';
      if (!byProvider[p]) byProvider[p] = { requests: 0, input_tokens: 0, output_tokens: 0 };
      byProvider[p].requests++;
      byProvider[p].input_tokens += log.input_tokens || 0;
      byProvider[p].output_tokens += log.output_tokens || 0;
    }

    return res.status(200).json({
      period_start: today.toISOString(),
      period_end: null,
      total_requests: totalRequests,
      total_input_tokens: totalInputTokens,
      total_output_tokens: totalOutputTokens,
      total_cost_cents: totalCostCents,
      daily_limit: 100_000,
      by_provider: byProvider,
    });
  } catch (err) {
    console.error('Usage error:', err);
    return res.status(500).json({ error: 'Failed to fetch usage' });
  }
}
