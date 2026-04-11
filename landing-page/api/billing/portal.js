export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Not authenticated' });
  }
  const jwt = authHeader.slice(7);

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;
  const RZP_KEY_ID = process.env.RAZORPAY_KEY_ID;
  const RZP_KEY_SECRET = process.env.RAZORPAY_KEY_SECRET;
  const rzpAuth = Buffer.from(`${RZP_KEY_ID}:${RZP_KEY_SECRET}`).toString('base64');

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
    // Get active subscription from Supabase
    const subRow = await fetch(
      `${SUPABASE_URL}/rest/v1/subscriptions?user_id=eq.${user.id}&status=eq.active&select=stripe_subscription_id&limit=1`,
      { headers: { 'apikey': SUPABASE_KEY, 'Authorization': `Bearer ${SUPABASE_KEY}` } }
    ).then(r => r.json());

    const subscriptionId = subRow?.[0]?.stripe_subscription_id;
    if (!subscriptionId) {
      return res.status(400).json({ error: 'No active subscription found.' });
    }

    // Razorpay doesn't have a customer portal like Stripe.
    // We can cancel or return subscription details for the app to display.
    const action = req.body?.action; // 'cancel' or 'details'

    if (action === 'cancel') {
      const cancelRes = await fetch(`https://api.razorpay.com/v1/subscriptions/${subscriptionId}/cancel`, {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${rzpAuth}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ cancel_at_cycle_end: 1 }), // Cancel at end of current period
      });
      const result = await cancelRes.json();

      if (result.error) {
        return res.status(500).json({ error: result.error.description });
      }

      // Update Supabase
      await fetch(`${SUPABASE_URL}/rest/v1/subscriptions?stripe_subscription_id=eq.${subscriptionId}`, {
        method: 'PATCH',
        headers: {
          'apikey': SUPABASE_KEY,
          'Authorization': `Bearer ${SUPABASE_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ status: 'canceled' }),
      });

      return res.status(200).json({ success: true, message: 'Subscription will cancel at end of billing period.' });
    }

    // Default: return subscription details
    const detailsRes = await fetch(`https://api.razorpay.com/v1/subscriptions/${subscriptionId}`, {
      headers: { 'Authorization': `Basic ${rzpAuth}` },
    });
    const details = await detailsRes.json();

    return res.status(200).json({
      subscription_id: details.id,
      status: details.status,
      current_end: details.current_end ? new Date(details.current_end * 1000).toISOString() : null,
      plan_id: details.plan_id,
    });
  } catch (err) {
    console.error('Portal error:', err);
    return res.status(500).json({ error: 'Failed to manage subscription' });
  }
}
