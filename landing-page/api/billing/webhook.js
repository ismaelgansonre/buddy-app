import crypto from 'crypto';

export const config = { api: { bodyParser: false } };

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).end();

  const WEBHOOK_SECRET = process.env.RAZORPAY_WEBHOOK_SECRET;
  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;

  // Read raw body
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const rawBody = Buffer.concat(chunks).toString('utf8');

  // Verify Razorpay signature
  const sig = req.headers['x-razorpay-signature'];
  if (!sig || !WEBHOOK_SECRET) {
    return res.status(400).json({ error: 'Missing signature' });
  }

  const expected = crypto
    .createHmac('sha256', WEBHOOK_SECRET)
    .update(rawBody)
    .digest('hex');

  if (expected !== sig) {
    return res.status(400).json({ error: 'Invalid signature' });
  }

  const event = JSON.parse(rawBody);
  const eventType = event.event;
  const payload = event.payload;

  try {
    switch (eventType) {
      case 'subscription.activated': {
        const sub = payload.subscription?.entity;
        const userId = sub?.notes?.user_id;
        if (userId && sub) {
          await upsertSubscription(SUPABASE_URL, SUPABASE_KEY, {
            user_id: userId,
            stripe_subscription_id: sub.id, // reusing column name for razorpay sub id
            status: 'active',
            plan: sub.plan_id,
            current_period_end: sub.current_end
              ? new Date(sub.current_end * 1000).toISOString()
              : null,
          });
        }
        break;
      }

      case 'subscription.charged': {
        const sub = payload.subscription?.entity;
        const userId = sub?.notes?.user_id;
        if (userId && sub) {
          await upsertSubscription(SUPABASE_URL, SUPABASE_KEY, {
            user_id: userId,
            stripe_subscription_id: sub.id,
            status: 'active',
            current_period_end: sub.current_end
              ? new Date(sub.current_end * 1000).toISOString()
              : null,
          });
        }
        break;
      }

      case 'subscription.completed':
      case 'subscription.cancelled': {
        const sub = payload.subscription?.entity;
        const userId = sub?.notes?.user_id;
        if (userId && sub) {
          await upsertSubscription(SUPABASE_URL, SUPABASE_KEY, {
            user_id: userId,
            stripe_subscription_id: sub.id,
            status: 'canceled',
            current_period_end: sub.current_end
              ? new Date(sub.current_end * 1000).toISOString()
              : null,
          });
        }
        break;
      }

      case 'subscription.halted':
      case 'subscription.pending': {
        const sub = payload.subscription?.entity;
        const userId = sub?.notes?.user_id;
        if (userId && sub) {
          await upsertSubscription(SUPABASE_URL, SUPABASE_KEY, {
            user_id: userId,
            stripe_subscription_id: sub.id,
            status: 'past_due',
          });
        }
        break;
      }
    }

    return res.status(200).json({ received: true });
  } catch (err) {
    console.error('Webhook error:', err);
    return res.status(500).json({ error: 'Webhook processing failed' });
  }
}

async function upsertSubscription(supabaseUrl, supabaseKey, data) {
  await fetch(`${supabaseUrl}/rest/v1/subscriptions`, {
    method: 'POST',
    headers: {
      'apikey': supabaseKey,
      'Authorization': `Bearer ${supabaseKey}`,
      'Content-Type': 'application/json',
      'Prefer': 'resolution=merge-duplicates',
    },
    body: JSON.stringify(data),
  });
}
