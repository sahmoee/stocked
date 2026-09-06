"""Source-wiring checks, not device UI tests. Native state checks cover count behavior."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class FinderRefreshContract(unittest.TestCase):
    def test_query_cannot_restart_download(self):
        text = (ROOT / "Stocked/RecipeFinderView.swift").read_text()
        model = text.split("struct RecipeFinderView: View", 1)[0]
        self.assertNotIn("refreshFullCatalogue()", model)
        self.assertIn("requestState.phase == .ready, completedKey == key", model)

    def test_background_recipe_revisions_do_not_restart_search(self):
        text = (ROOT / "Stocked/RecipeFinderView.swift").read_text()
        for revision in ["session.guestStore.recipeRevision", "session.guestStore.pastMealsRevision",
                         "RecipeDatabaseManager.shared.recipesVersion", "RecipeDatabaseManager.shared.catalogueRevision"]:
            self.assertNotIn(".onChange(of: " + revision + ")", text)
        self.assertNotIn(".onChange(of: HarvestRecipeSync.shared.refreshingCatalogue)", text)
        self.assertIn("if model.flow.filters.usesInventory { refresh() }", text)
        self.assertIn(".onChange(of: session.guestStore.cookingProfile.allergens)", text)

    def test_partial_grid_and_count_wiring(self):
        data = (ROOT / "Stocked/RecipeFinderData.swift").read_text()
        view = (ROOT / "Stocked/RecipeFinderView.swift").read_text()
        self.assertIn("count - lastPreviewCount >= 20", data)
        self.assertIn("mergeVisible(response.hits)", view)
        self.assertIn("merged.append(hit)", view)
        self.assertNotIn("so far", view)
        self.assertNotIn('Text("\\(model.count)', view)
        self.assertIn('private var showCount: String { model.loading ? "Finding matches…" : "See recipes" }', view)
        self.assertIn("model.canReportCount && model.count == 0", view)

if __name__ == "__main__": unittest.main()
