export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { email } = req.body;
  if (!email || !email.includes('@')) {
    return res.status(400).json({ error: 'Valid email required' });
  }

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;

  try {
    const redirectTo = 'https://buddy.artiphik.com/auth/callback';
    const magicRes = await fetch(`${SUPABASE_URL}/auth/v1/magiclink?redirect_to=${encodeURIComponent(redirectTo)}`, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email: email.toLowerCase().trim(),
      }),
    });

    if (!magicRes.ok) {
      const err = await magicRes.text();
      console.error('Magic link error:', err);
      return res.status(magicRes.status).json({ error: 'Could not send sign-in link. Try again.' });
    }

    return res.status(200).json({
      success: true,
      message: 'Check your email for a sign-in link.',
    });
  } catch (err) {
    console.error('Magic link error:', err);
    return res.status(500).json({ error: 'Something went wrong. Try again.' });
  }
}
