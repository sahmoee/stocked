#!/usr/bin/env python3
"""Synthetic interoperability fixtures. Uses Python's standard library, no application code or recipes."""
import base64
import gzip
import io
import json
from pathlib import Path
import struct
import sys
import zipfile
import zlib

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)


def png(width=1, height=1):
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\0\0\0\0\xff')) + chunk(b'IEND', b'')


def data(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True).encode()


def archive(entries):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zipout:
        for name, content in entries:
            zipout.writestr(name, content)
    return out.getvalue()


photo = png()
schema = {
    '@context': 'https://schema.org', '@type': 'Recipe', 'name': 'Fixture café rice',
    'recipeIngredient': ['1 cup cooked rice', '1 cup dry rice'],
    'recipeInstructions': [{'@type': 'HowToStep', 'text': 'Combine and serve.'}],
    'url': 'https://example.org/Recipes/Case',
    'author': {'@type': 'Person', 'name': 'Fixture Writer'}, 'license': 'CC BY 4.0',
    'image': {'url': 'https://example.org/data/images/photo.png', 'name': 'Photo caption', 'creditText': 'Fixture Photographer'},
    'comment': {'@type': 'Comment', 'text': 'A private family note.'},
}
mealie = {
    'name': 'Fixture Mealie', 'recipe_servings': 4, 'org_url': 'https://example.org/mealie',
    'recipe_ingredient': [{'quantity': 1, 'unit': {'name': 'cup'}, 'food': {'name': 'cooked rice'}, 'note': 'chilled'}, {'display': '2 eggs, beaten', 'quantity': 99}],
    'recipe_instructions': [{'title': 'Finish', 'text': 'Mix gently.'}],
    'notes': [{'title': 'Family note', 'text': 'Keep chilled.'}],
    'tags': [{'name': 'Simple'}], 'recipe_category': [{'name': 'Lunch'}],
    'user_id': 'private-user-id', 'household_id': 'private-household-id', 'image': 'version-token',
    'nutrition': {'calories': '200', 'protein_content': '3 g'},
}
tandoor = {
    'name': 'Fixture Tandoor', 'source_url': 'https://example.org/tandoor',
    'servings': 2, 'servings_text': 'bowls', 'working_time': 5, 'waiting_time': 60,
    'steps': [
        {'order': 2, 'name': 'Serve', 'instruction': 'Serve after resting.', 'ingredients': [{'order': 1, 'food': {'name': 'salt'}, 'unit': {'name': 'tsp'}, 'amount': 9, 'no_amount': True}]},
        {'order': 1, 'name': 'Mix', 'instruction': 'Mix ingredients.', 'ingredients': [{'order': 1, 'food': {'name': 'dry rice'}, 'unit': {'name': 'cup'}, 'amount': '0.5', 'note': 'rinsed'}]},
    ],
}
paprika = {
    'name': 'Fixture Paprika', 'ingredients': '1 lemon\n2 tbsp water', 'directions': 'Squeeze lemon.\nMix with water.',
    'source': 'Fixture Publisher', 'source_url': 'https://example.org/paprika',
    'servings': '2 glasses', 'prep_time': '5 minutes', 'cook_time': '', 'notes': 'Private note.',
    'photo_data': base64.b64encode(photo).decode(), 'categories': ['Drinks'],
}
(root / 'schema.json').write_bytes(data(schema))
(root / 'photo.png').write_bytes(photo)
(root / 'mealie.json').write_bytes(data(mealie))
(root / 'tandoor.json').write_bytes(data(tandoor))
(root / 'paprika.json').write_bytes(data(paprika))
(root / 'mealie.zip').write_bytes(archive([('recipes/fixture/fixture.json', data(mealie)), ('recipes/fixture/images/original.png', photo)]))
inner = archive([('recipe.json', data(tandoor)), ('image.png', photo)])
(root / 'tandoor.zip').write_bytes(archive([('42.zip', inner)]))
(root / 'recipya.zip').write_bytes(archive([('Fixture café rice/recipe.json', data(schema)), ('Fixture café rice/photo.png', photo)]))
(root / 'paprika.paprikarecipes').write_bytes(archive([('fixture.paprikarecipe', gzip.compress(data(paprika), mtime=0))]))
without_photo = dict(paprika, photo_data='')
(root / 'plain.paprikarecipe').write_bytes(gzip.compress(data(without_photo), mtime=0))
(root / 'duplicates.zip').write_bytes(archive([('one.json', data(schema)), ('two.json', json.dumps(schema, indent=2).encode())]))
changed = dict(schema, extra='Distinct source metadata must survive as a separate review candidate.')
(root / 'changed.json').write_bytes(data([schema, changed]))
(root / 'array.json').write_bytes(data([schema, dict(schema, name='Second recipe')]))
(root / 'wrapper.json').write_bytes(data({'recipes': [without_photo, schema, mealie, tandoor, {'name': 'Settings'}]}))
aliased_mealie = {'@type': 'Recipe', 'name': 'Aliased Mealie', 'recipeIngredient': mealie['recipe_ingredient'], 'recipeInstructions': mealie['recipe_instructions'], 'orgURL': 'https://example.org/aliased'}
(root / 'aliased-mealie.json').write_bytes(data(aliased_mealie))
(root / 'inline-array-photo.json').write_bytes(data(dict(schema, image=['data:image/png;base64,' + base64.b64encode(photo).decode()])))
(root / 'heading-only.json').write_bytes(data(dict(tandoor, steps=[{'name': 'Heading only', 'instruction': '', 'ingredients': tandoor['steps'][1]['ingredients']}])))
(root / 'graph.json').write_bytes(data({'@graph': [{'@type': 'Organization', 'name': 'Not a recipe'}, schema]}))
(root / 'image-isolation.zip').write_bytes(archive([('A/recipe.json', data(schema)), ('B/photo.png', photo)]))
(root / 'huge-photo.zip').write_bytes(archive([('A/recipe.json', data(schema)), ('A/photo.png', png(20_000, 20_000))]))
(root / 'webp.zip').write_bytes(archive([('recipes/fixture/fixture.json', data(mealie)), ('recipes/fixture/images/original.webp', b'RIFFfakeWEBP')]))
(root / 'partial.zip').write_bytes(archive([('valid.json', data(schema)), ('broken.json', b'{broken'), ('settings.json', data({'name': 'Account settings', 'token': 'synthetic-not-a-secret'}))]))
(root / 'too-many.json').write_bytes(data([schema] * 251))
(root / 'too-large.json').write_bytes(data(dict(schema, recipeInstructions=['x' * (49 * 1024)])))
(root / 'big-original.json').write_bytes(data(dict(schema, privateExtra='x' * (50 * 1024))))
(root / 'no-recipes.zip').write_bytes(archive([('settings.json', data({'name': 'Settings'}))]))
(root / 'deep.zip').write_bytes(archive([('one.zip', archive([('two.zip', inner)]))]))
(root / 'too-many-entries.zip').write_bytes(archive([('one.zip', archive([(f'{i}.txt', b'x') for i in range(499)])), ('two.zip', inner)]))
(root / 'too-many-directories.zip').write_bytes(archive([('one.zip', archive([(f'd{i}/', b'') for i in range(499)])), ('two.zip', inner)]))
fat_recipe = dict(schema, privateExtra='x' * (7 * 1024 * 1024))
fat_gzip = gzip.compress(data(fat_recipe), mtime=0)
(root / 'gzip-budget.zip').write_bytes(archive([(f'{i}.json.gz', fat_gzip) for i in range(5)]))
# Each inner archive stays below 32 MB; their combined expansion must not bypass the global limit.
inners = [(f'{i}.zip', archive([(f'{i}.json', data(dict(fat_recipe, name=f'Large source {i}')))])) for i in range(5)]
(root / 'nested-budget.zip').write_bytes(archive(inners))
print(f'Prepared {len(list(root.iterdir()))} synthetic migration fixtures.')
