"""Native regression: actual migration + actual recipe Codable models, no user stores."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def declaration(path, marker):
    text = (ROOT / path).read_text()
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    # Swift 6.1 CLI cannot parse newer type-level nonisolated; no behavioral change.
    return text[start:end].replace('nonisolated ', '')

with tempfile.TemporaryDirectory(prefix='stocked-hydration-') as directory:
    models = Path(directory) / 'RecipeModels.swift'
    models.write_text('import Foundation\nimport CryptoKit\n' + '\n'.join([
        declaration('Stocked/Models.swift', 'nonisolated struct NutritionFacts'),
        declaration('Stocked/Models.swift', 'nonisolated struct RecipeIngredient:'),
        declaration('Stocked/Models.swift', 'nonisolated struct UserRecipe:'),
        declaration('Stocked/PortableRecipeFiles.swift', 'nonisolated struct PortableRecipeSource:'),
        declaration('Stocked/CookingSessionModel.swift', 'nonisolated enum DishRole:'),
    ]))
    policy = Path(directory) / 'RecipeDisplayPolicy.swift'
    policy.write_text((ROOT / 'Stocked/RecipeDisplayPolicy.swift').read_text().replace('nonisolated ', ''))
    binary = Path(directory) / 'hydration-checks'
    subprocess.run(['xcrun', 'swiftc', str(models), str(ROOT / 'Stocked/DBMigration.swift'), str(policy),
                    str(ROOT / 'scripts/RecipeHydrationChecks.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
