Recipe images go here, named by recipe id from recipes.json.

Examples (must match the "image" field in recipes.json):
  001.jpg   → referenced as "img/recipes/001.jpg"
  002.jpg
  003.jpg
  004.jpg
  005.jpg

Guidelines:
- JPG or WebP, ~1200px wide, compressed to ~150–300 KB each.
- Landscape (roughly 4:3 or 16:9) looks best on the recipe cards.
- The app tolerates missing images — a recipe with no image (or a not-yet-uploaded
  one) still shows; it just renders without a photo. So you can publish recipes.json
  first and add images over time.

Reminder: this cPanel plan has a 300,000-file (inode) cap. A few hundred recipe
images is nothing, but don't try to mirror tens of thousands of files here.
