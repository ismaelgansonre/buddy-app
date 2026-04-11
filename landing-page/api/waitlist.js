export default async function handler(req, res) {
  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    return res.status(200).end();
  }

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { name, email } = req.body;

  if (!email || !email.includes('@')) {
    return res.status(400).json({ error: 'Valid email required' });
  }

  if (!name || name.trim().length === 0) {
    return res.status(400).json({ error: 'Name required' });
  }

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;

  try {
    // Check if email already exists
    const checkRes = await fetch(
      `${SUPABASE_URL}/rest/v1/waitlist?email=eq.${encodeURIComponent(email.toLowerCase().trim())}`,
      {
        headers: {
          'apikey': SUPABASE_KEY,
          'Authorization': `Bearer ${SUPABASE_KEY}`,
        },
      }
    );

    const existing = await checkRes.json();

    if (existing && existing.length > 0) {
      return res.status(200).json({
        success: true,
        message: "You're already on the list!",
        already_exists: true
      });
    }

    // Insert new entry
    const insertRes = await fetch(`${SUPABASE_URL}/rest/v1/waitlist`, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_KEY,
        'Authorization': `Bearer ${SUPABASE_KEY}`,
        'Content-Type': 'application/json',
        'Prefer': 'return=representation',
      },
      body: JSON.stringify({
        name: name.trim(),
        email: email.toLowerCase().trim(),
        verified: false,
        source: 'landing_page',
      }),
    });

    if (!insertRes.ok) {
      const errText = await insertRes.text();
      console.error('Supabase insert error:', errText);
      return res.status(500).json({ error: 'Failed to save. Try again.' });
    }

    // Get total count for social proof
    const countRes = await fetch(
      `${SUPABASE_URL}/rest/v1/waitlist?select=id`,
      {
        headers: {
          'apikey': SUPABASE_KEY,
          'Authorization': `Bearer ${SUPABASE_KEY}`,
          'Prefer': 'count=exact',
        },
      }
    );

    const totalCount = parseInt(countRes.headers.get('content-range')?.split('/')[1] || '0');

    return res.status(200).json({
      success: true,
      message: "You're on the list! Buddy's excited.",
      total_count: totalCount,
    });

  } catch (err) {
    console.error('Waitlist error:', err);
    return res.status(500).json({ error: 'Something went wrong. Try again.' });
  }
}
