#!/bin/zsh
# เปิด Friday โหมดห้อง: Chrome แยกโปรไฟล์ (หน้าต่างแอป) + อนุญาตเล่นเสียงเองไม่ต้องแตะ
exec /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --user-data-dir="$HOME/.friday-chrome" --no-first-run --no-default-browser-check \
  --autoplay-policy=no-user-gesture-required \
  --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows \
  --app="http://localhost:4850/?room=1" --window-size=420,760
