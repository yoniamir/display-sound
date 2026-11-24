// Counts each download of a release file per day, then serves the file.
// Nothing about the visitor is stored: only the date, the file name and a count.
export async function onRequestGet({ request, env, params, waitUntil }) {
  const response = await env.ASSETS.fetch(request);
  const range = request.headers.get("Range");
  const firstByte = !range || /^bytes=0-/.test(range);
  if (response.ok && params.name.endsWith(".zip") && firstByte) {
    const day = new Date().toISOString().slice(0, 10);
    waitUntil(
      env.DB.prepare(
        "INSERT INTO downloads (day, file, count) VALUES (?1, ?2, 1) " +
        "ON CONFLICT (day, file) DO UPDATE SET count = count + 1"
      ).bind(day, params.name).run().catch(() => {})
    );
  }
  return response;
}
