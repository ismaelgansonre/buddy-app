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
    // Check if user already has a Razorpay customer ID
    const userRow = await fetch(
      `${SUPABASE_URL}/rest/v1/users?id=eq.${user.id}&select=stripe_customer_id`,
      { headers: { 'apikey': SUPABASE_KEY, 'Authorization': `Bearer ${SUPABASE_KEY}` } }
    ).then(r => r.json());

    let customerId = userRow?.[0]?.stripe_customer_id; // reusing column name

    // Create Razorpay customer if needed
    if (!customerId) {
      const customerRes = await fetch('https://api.razorpay.com/v1/customers', {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${rzpAuth}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          name: user.email.split('@')[0],
          email: user.email,
          notes: { user_id: user.id },
        }),
      });
      const customer = await customerRes.json();
      customerId = customer.id;

      await fetch(`${SUPABASE_URL}/rest/v1/users?id=eq.${user.id}`, {
        method: 'PATCH',
        headers: {
          'apikey': SUPABASE_KEY,
          'Authorization': `Bearer ${SUPABASE_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ stripe_customer_id: customerId }),
      });
    }

    // Create Razorpay Subscription
    const planId = process.env.RAZORPAY_PLAN_ID;
    const subRes = await fetch('https://api.razorpay.com/v1/subscriptions', {
      method: 'POST',
      headers: {
        'Authorization': `Basic ${rzpAuth}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        plan_id: planId,
        customer_id: customerId,
        total_count: 12, // 12 billing cycles
        notes: { user_id: user.id },
      }),
    });

    const subscription = await subRes.json();
    if (subscription.error) {
      return res.status(500).json({ error: subscription.error.description });
    }

    // Return the subscription short_url for Razorpay hosted checkout
    return res.status(200).json({
      url: subscription.short_url,
      subscription_id: subscription.id,
    });
  } catch (err) {
    console.error('Checkout error:', err);
    return res.status(500).json({ error: 'Failed to create checkout session' });
  }
}
