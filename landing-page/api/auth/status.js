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

  // Verify user with Supabase
  let user;
  try {
    const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { 'apikey': SUPABASE_KEY, 'Authorization': `Bearer ${jwt}` },
    });
    if (!userRes.ok) return res.status(401).json({ error: 'Invalid or expired token' });
    user = await userRes.json();
  } catch {
    return res.status(401).json({ error: 'Auth verification failed' });
  }

  // Check for active subscription
  try {
    const subRes = await fetch(
      `${SUPABASE_URL}/rest/v1/subscriptions?user_id=eq.${user.id}&status=eq.active&select=id,plan,status,current_period_end&limit=1`,
      { headers: { 'apikey': SUPABASE_KEY, 'Authorization': `Bearer ${SUPABASE_KEY}` } }
    );
    const subs = await subRes.json();
    const hasSubscription = Array.isArray(subs) && subs.length > 0;

    return res.status(200).json({
      authenticated: true,
      email: user.email,
      user_id: user.id,
      has_subscription: hasSubscription,
      subscription: hasSubscription ? {
        status: subs[0].status,
        plan: subs[0].plan,
        current_period_end: subs[0].current_period_end,
      } : null,
    });
  } catch (err) {
    console.error('Status check error:', err);
    return res.status(500).json({ error: 'Failed to check subscription status' });
  }
}
