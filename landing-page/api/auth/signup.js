export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { email, password } = req.body;
  if (!email || !email.includes('@')) {
    return res.status(400).json({ error: 'Valid email required' });
  }
  if (!password || password.length < 6) {
    return res.status(400).json({ error: 'Password must be at least 6 characters' });
  }

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;
  const cleanEmail = email.toLowerCase().trim();

  try {
    // Use admin API to create user with auto-confirmed email
    // This bypasses the email confirmation requirement entirely
    const createRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_KEY,
        'Authorization': `Bearer ${SUPABASE_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email: cleanEmail,
        password,
        email_confirm: true,
      }),
    });

    const createData = await createRes.json();

    if (!createRes.ok) {
      const msg = createData?.msg || createData?.message || createData?.error_description || 'Signup failed';
      // Check if user already exists
      if (msg.toLowerCase().includes('already') || createRes.status === 422) {
        return res.status(409).json({ error: 'An account with this email already exists. Try signing in.' });
      }
      return res.status(createRes.status).json({ error: msg });
    }

    // Now sign them in to get access + refresh tokens
    const tokenRes = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email: cleanEmail,
        password,
      }),
    });

    const tokenData = await tokenRes.json();

    if (!tokenRes.ok) {
      // Account was created but couldn't get tokens — tell user to sign in
      return res.status(200).json({
        needs_signin: true,
        message: 'Account created! Please sign in.',
      });
    }

    return res.status(200).json({
      access_token: tokenData.access_token,
      refresh_token: tokenData.refresh_token,
      user: { id: createData.id, email: createData.email },
    });
  } catch (err) {
    console.error('Signup error:', err);
    return res.status(500).json({ error: 'Something went wrong. Try again.' });
  }
}
