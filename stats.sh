#!/bin/sh
# Prints download counts from the live site, per file and per day.
cd "$(dirname "$0")"
npx -y wrangler d1 execute display-sound --remote --command \
  "SELECT file, SUM(count) AS total FROM downloads GROUP BY file; SELECT day, file, count FROM downloads ORDER BY day DESC LIMIT 30;"
