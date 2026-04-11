export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Cache-Control', 's-maxage=60, stale-while-revalidate=300');

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_KEY = process.env.SUPABASE_SERVICE_KEY;

  try {
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

    return res.status(200).json({ total_count: totalCount });
  } catch (err) {
    return res.status(200).json({ total_count: 0 });
  }
}
