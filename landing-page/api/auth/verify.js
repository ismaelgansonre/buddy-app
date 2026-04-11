export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { token, type } = req.body;
  if (!token) {
    return res.status(400).json({ error: 'Token required' });
  }

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;

  try {
    // Verify the OTP/magic link token
    const verifyRes = await fetch(`${SUPABASE_URL}/auth/v1/verify`, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        token,
        type: type || 'magiclink',
      }),
    });

    if (!verifyRes.ok) {
      const err = await verifyRes.text();
      console.error('Verify error:', err);
      return res.status(401).json({ error: 'Invalid or expired link. Try signing in again.' });
    }

    const session = await verifyRes.json();

    // Ensure user record exists in our users table
    const userId = session.user?.id;
    const email = session.user?.email;
    if (userId && email) {
      await fetch(`${SUPABASE_URL}/rest/v1/users`, {
        method: 'POST',
        headers: {
          'apikey': SUPABASE_KEY,
          'Authorization': `Bearer ${SUPABASE_KEY}`,
          'Content-Type': 'application/json',
          'Prefer': 'resolution=merge-duplicates',
        },
        body: JSON.stringify({ id: userId, email }),
      });
    }

    return res.status(200).json({
      success: true,
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      user: {
        id: session.user?.id,
        email: session.user?.email,
      },
    });
  } catch (err) {
    console.error('Verify error:', err);
    return res.status(500).json({ error: 'Something went wrong. Try again.' });
  }
}
