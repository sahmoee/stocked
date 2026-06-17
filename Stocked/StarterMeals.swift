import Foundation

// ─────────────────────────────────────────────────────────────────────
// Build 247 — Starter meal catalog.
//
// WHY: The Cook tab's "Cook Now" rail and "Cook Later" list matched only
// against the user's SAVED recipes — a fresh kitchen with a stocked pantry
// but no saved recipes showed two empty placeholders forever. These are
// curated, everyday meals the matcher blends in (see GuestDataStore.cookCatalog)
// so both sections populate honestly from day one: "2 missing" is computed
// live against the actual pantry, exactly like a saved recipe.
//
// Rules for entries here:
//   • FIXED UUIDs — recreating these with fresh ids each access would break
//     ForEach identity and navigation state. Never change an id once shipped.
//   • Ingredient NAMES are chosen for looseMatch-ability against common pantry
//     item names ("tortillas" not "taco shells", "tomatoes" not "tomato sauce").
//   • Garnish/serve-with items are isOptional so they don't inflate the
//     missing count out of the Cook Later 1–3 band.
//   • Saved recipes always win: cookCatalog dedupes by normalized title.
// ─────────────────────────────────────────────────────────────────────

nonisolated enum StarterMeals {

    private static func ing(_ name: String, _ amount: String, optional: Bool = false) -> RecipeIngredient {
        RecipeIngredient(name: name, amount: amount, isOptional: optional)
    }

    static let all: [UserRecipe] = [

        // ── The six from the design mockup ───────────────────────────

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0001-4000-8000-000000000001")!,
            title: "Garlic Butter Chicken",
            description: "Juicy pan-seared chicken in a rich garlic butter sauce. A weeknight classic that comes together in one skillet.",
            cookTime: "30 min", prepTime: "10 min", servings: 4, difficulty: "Easy", cuisine: "American",
            tags: ["Starter", "Dinner", "One Pan"],
            ingredients: [
                ing("chicken breast", "4 boneless breasts"),
                ing("butter", "4 tbsp"),
                ing("garlic", "5 cloves, minced"),
                ing("olive oil", "1 tbsp"),
                ing("salt", "to taste"),
                ing("black pepper", "to taste"),
                ing("parsley", "chopped, for garnish", optional: true),
                ing("lemon", "1, juiced", optional: true)
            ],
            instructions: [
                "Pat the chicken dry and season both sides generously with salt and pepper.",
                "Heat the olive oil in a large skillet over medium-high heat.",
                "Sear the chicken 5–6 minutes per side until golden and cooked through (165°F). Remove to a plate.",
                "Lower the heat, add the butter and garlic, and cook 1 minute until fragrant — don't let the garlic brown.",
                "Return the chicken to the pan and spoon the garlic butter over the top for 2 minutes.",
                "Finish with lemon juice and parsley if you have them, and serve."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0002-4000-8000-000000000002")!,
            title: "Veggie Stir Fry",
            description: "Crisp vegetables tossed in a garlicky soy glaze over steamed rice. Endlessly flexible — use whatever's in the crisper.",
            cookTime: "20 min", prepTime: "10 min", servings: 4, difficulty: "Easy", cuisine: "Asian",
            tags: ["Starter", "Vegetarian", "Quick"],
            ingredients: [
                ing("broccoli", "2 cups florets"),
                ing("carrot", "2, sliced thin"),
                ing("bell pepper", "1, sliced"),
                ing("soy sauce", "3 tbsp"),
                ing("garlic", "3 cloves, minced"),
                ing("rice", "2 cups cooked"),
                ing("vegetable oil", "2 tbsp"),
                ing("ginger", "1 tsp, grated", optional: true),
                ing("sesame seeds", "for garnish", optional: true)
            ],
            instructions: [
                "Cook the rice and keep it warm.",
                "Heat the oil in a wok or large skillet over high heat until shimmering.",
                "Add the carrots and broccoli; stir-fry 3 minutes.",
                "Add the bell pepper, garlic, and ginger; stir-fry 2 more minutes until crisp-tender.",
                "Pour in the soy sauce and toss to coat everything in the glaze.",
                "Serve over the rice and top with sesame seeds."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0003-4000-8000-000000000003")!,
            title: "Chicken Quesadillas",
            description: "Golden tortillas stuffed with seasoned chicken, melty cheese, and sautéed peppers. Crispy outside, gooey inside.",
            cookTime: "25 min", prepTime: "10 min", servings: 4, difficulty: "Easy", cuisine: "Mexican",
            tags: ["Starter", "Lunch", "Kid Friendly"],
            ingredients: [
                ing("chicken breast", "2, cooked and shredded"),
                ing("tortillas", "4 large flour"),
                ing("cheese", "2 cups shredded"),
                ing("bell pepper", "1, sliced"),
                ing("onion", "1/2, sliced"),
                ing("sour cream", "for serving", optional: true),
                ing("salsa", "for serving", optional: true)
            ],
            instructions: [
                "Sauté the onion and bell pepper in a little oil until soft, about 5 minutes.",
                "Lay a tortilla flat; cover half with cheese, chicken, and the sautéed vegetables, then a little more cheese. Fold over.",
                "Toast in a dry skillet over medium heat 2–3 minutes per side until golden and the cheese melts.",
                "Repeat with the remaining tortillas.",
                "Slice into wedges and serve with sour cream and salsa."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0004-4000-8000-000000000004")!,
            title: "Chicken Alfredo",
            description: "Fettuccine in a silky parmesan cream sauce with golden sliced chicken. Restaurant comfort food from your own stove.",
            cookTime: "30 min", prepTime: "10 min", servings: 4, difficulty: "Medium", cuisine: "Italian",
            tags: ["Starter", "Dinner", "Comfort Food"],
            ingredients: [
                ing("pasta", "12 oz fettuccine"),
                ing("chicken breast", "2, sliced"),
                ing("heavy cream", "1 1/2 cups"),
                ing("parmesan cheese", "1 cup, grated"),
                ing("butter", "3 tbsp"),
                ing("garlic", "3 cloves, minced"),
                ing("parsley", "chopped, for garnish", optional: true)
            ],
            instructions: [
                "Cook the pasta in salted water until al dente; reserve 1/2 cup pasta water before draining.",
                "Season and sear the chicken slices in a skillet until golden and cooked through; set aside.",
                "In the same pan, melt the butter and cook the garlic 1 minute.",
                "Pour in the cream, bring to a gentle simmer, and whisk in the parmesan until smooth.",
                "Toss in the pasta and chicken, loosening with pasta water as needed.",
                "Top with parsley and extra parmesan."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0005-4000-8000-000000000005")!,
            title: "Beef Tacos",
            description: "Seasoned ground beef piled into warm tortillas with crisp lettuce, cheese, and salsa. Taco night, solved.",
            cookTime: "20 min", prepTime: "10 min", servings: 4, difficulty: "Easy", cuisine: "Mexican",
            tags: ["Starter", "Dinner", "Quick"],
            ingredients: [
                ing("ground beef", "1 lb"),
                ing("tortillas", "8 small"),
                ing("cheese", "1 cup shredded"),
                ing("lettuce", "2 cups shredded"),
                ing("salsa", "1 cup"),
                ing("onion", "1/2, diced", optional: true),
                ing("sour cream", "for serving", optional: true)
            ],
            instructions: [
                "Brown the ground beef in a skillet over medium-high heat, breaking it up as it cooks; drain excess fat.",
                "Season with salt, pepper, and any taco spices you have (chili powder, cumin, paprika).",
                "Warm the tortillas in a dry pan or directly over a low flame.",
                "Build the tacos: beef, then cheese, lettuce, and salsa.",
                "Top with onion and sour cream if you like."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0006-4000-8000-000000000006")!,
            title: "Corn Chowder",
            description: "A creamy, cozy bowl of sweet corn and tender potatoes. Tastes like it simmered all day — ready in about half an hour.",
            cookTime: "35 min", prepTime: "10 min", servings: 4, difficulty: "Easy", cuisine: "American",
            tags: ["Starter", "Soup", "Comfort Food"],
            ingredients: [
                ing("corn", "3 cups kernels"),
                ing("potato", "2, diced"),
                ing("onion", "1, diced"),
                ing("milk", "2 cups"),
                ing("butter", "2 tbsp"),
                ing("chicken broth", "2 cups"),
                ing("bacon", "4 strips, chopped", optional: true),
                ing("celery", "2 stalks, diced", optional: true)
            ],
            instructions: [
                "If using bacon, crisp it in the pot first and set aside, leaving the fat.",
                "Melt the butter and sweat the onion (and celery) until soft, about 5 minutes.",
                "Add the potatoes and broth; simmer 12–15 minutes until the potatoes are tender.",
                "Stir in the corn and milk; simmer gently 5 more minutes — don't boil.",
                "Mash a few potato chunks against the pot to thicken, season well, and serve topped with the bacon."
            ]
        ),

        // ── Low-ingredient meals — so sparse pantries still land in the
        //    Cook Now / 1–3 missing bands ───────────────────────────────

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0007-4000-8000-000000000007")!,
            title: "Garlic Butter Pasta",
            description: "Three pantry staples turned into a glossy, garlicky bowl of comfort. The fastest dinner there is.",
            cookTime: "15 min", prepTime: "5 min", servings: 2, difficulty: "Easy", cuisine: "Italian",
            tags: ["Starter", "Quick", "Vegetarian"],
            ingredients: [
                ing("pasta", "8 oz"),
                ing("butter", "4 tbsp"),
                ing("garlic", "4 cloves, sliced"),
                ing("parmesan cheese", "1/2 cup, grated", optional: true),
                ing("parsley", "chopped", optional: true)
            ],
            instructions: [
                "Cook the pasta in well-salted water; reserve 1/2 cup pasta water.",
                "Melt the butter in a skillet over medium-low and cook the garlic until just golden.",
                "Toss the pasta in the garlic butter with a splash of pasta water until glossy.",
                "Finish with parmesan and parsley if you have them."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0008-4000-8000-000000000008")!,
            title: "Scrambled Eggs & Toast",
            description: "Soft, creamy scrambled eggs on buttered toast. Breakfast for dinner is always allowed.",
            cookTime: "10 min", prepTime: "5 min", servings: 2, difficulty: "Easy", cuisine: "American",
            tags: ["Starter", "Breakfast", "Quick"],
            ingredients: [
                ing("eggs", "4 large"),
                ing("bread", "2 slices"),
                ing("butter", "2 tbsp"),
                ing("milk", "2 tbsp", optional: true)
            ],
            instructions: [
                "Whisk the eggs with a pinch of salt (and the milk, if using).",
                "Toast and butter the bread.",
                "Melt the remaining butter in a nonstick pan over medium-low heat.",
                "Pour in the eggs and stir slowly with a spatula until just set and still glossy.",
                "Pile onto the toast and season with pepper."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0009-4000-8000-000000000009")!,
            title: "Grilled Cheese",
            description: "Golden, crunchy, and impossibly melty. The benchmark of simple cooking done right.",
            cookTime: "10 min", prepTime: "5 min", servings: 2, difficulty: "Easy", cuisine: "American",
            tags: ["Starter", "Lunch", "Kid Friendly"],
            ingredients: [
                ing("bread", "4 slices"),
                ing("cheese", "4 slices"),
                ing("butter", "2 tbsp, softened")
            ],
            instructions: [
                "Butter one side of every slice of bread.",
                "Build sandwiches with the cheese inside and the buttered sides facing OUT.",
                "Cook in a skillet over medium-low heat, 3–4 minutes per side, pressing gently, until deep golden and melted through.",
                "Rest 1 minute, then slice diagonally — it's the law."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0010-4000-8000-000000000010")!,
            title: "Veggie Fried Rice",
            description: "Day-old rice, a hot pan, and a splash of soy sauce — better than takeout and ready in 20.",
            cookTime: "20 min", prepTime: "10 min", servings: 4, difficulty: "Easy", cuisine: "Asian",
            tags: ["Starter", "Quick", "Vegetarian"],
            ingredients: [
                ing("rice", "3 cups cooked, chilled"),
                ing("eggs", "2"),
                ing("soy sauce", "3 tbsp"),
                ing("garlic", "2 cloves, minced"),
                ing("vegetable oil", "2 tbsp"),
                ing("carrot", "1, diced", optional: true),
                ing("peas", "1/2 cup", optional: true)
            ],
            instructions: [
                "Heat 1 tbsp oil in a wok over high heat; scramble the eggs and set aside.",
                "Add the remaining oil, then the garlic (and carrot/peas); stir-fry 2 minutes.",
                "Add the rice, breaking up clumps, and stir-fry 3–4 minutes until it starts to crisp.",
                "Pour the soy sauce around the edge of the pan and toss everything together.",
                "Fold in the eggs and serve hot."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0011-4000-8000-000000000011")!,
            title: "Tomato Basil Pasta",
            description: "A bright, garlicky tomato sauce that tastes like summer, tossed with whatever pasta shape you've got.",
            cookTime: "25 min", prepTime: "5 min", servings: 4, difficulty: "Easy", cuisine: "Italian",
            tags: ["Starter", "Vegetarian", "Dinner"],
            ingredients: [
                ing("pasta", "12 oz"),
                ing("tomatoes", "1 can (28 oz), crushed"),
                ing("garlic", "4 cloves, sliced"),
                ing("olive oil", "3 tbsp"),
                ing("basil", "a handful, torn", optional: true),
                ing("parmesan cheese", "for serving", optional: true)
            ],
            instructions: [
                "Warm the olive oil and garlic together in a pan over medium heat until the garlic turns pale gold.",
                "Add the tomatoes, season with salt, and simmer 15 minutes until thickened.",
                "Meanwhile, cook the pasta until just shy of al dente; reserve a cup of pasta water.",
                "Finish the pasta in the sauce with a splash of pasta water for the last 2 minutes.",
                "Tear in the basil and serve with parmesan."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0012-4000-8000-000000000012")!,
            title: "Chicken Rice Bowl",
            description: "Glazed chicken over fluffy rice — a clean, satisfying bowl you can build from basics.",
            cookTime: "25 min", prepTime: "10 min", servings: 2, difficulty: "Easy", cuisine: "Asian",
            tags: ["Starter", "Dinner", "Healthy"],
            ingredients: [
                ing("chicken breast", "2, cubed"),
                ing("rice", "2 cups cooked"),
                ing("soy sauce", "3 tbsp"),
                ing("garlic", "2 cloves, minced"),
                ing("broccoli", "1 cup florets, steamed", optional: true),
                ing("sesame seeds", "for garnish", optional: true)
            ],
            instructions: [
                "Sear the cubed chicken in a hot, lightly oiled pan until golden on all sides.",
                "Add the garlic and cook 30 seconds, then the soy sauce with a splash of water.",
                "Simmer 2–3 minutes until the chicken is cooked through and glazed.",
                "Serve over the rice with broccoli alongside and sesame seeds on top."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0013-4000-8000-000000000013")!,
            title: "Fluffy Pancakes",
            description: "Tall, golden, weekend-worthy pancakes from scratch — no box required.",
            cookTime: "20 min", prepTime: "10 min", servings: 4, difficulty: "Easy", cuisine: "American",
            tags: ["Starter", "Breakfast", "Kid Friendly"],
            ingredients: [
                ing("flour", "1 1/2 cups"),
                ing("eggs", "1 large"),
                ing("milk", "1 1/4 cups"),
                ing("butter", "3 tbsp, melted"),
                ing("sugar", "2 tbsp"),
                ing("baking powder", "1 tbsp", optional: true),
                ing("maple syrup", "for serving", optional: true)
            ],
            instructions: [
                "Whisk the flour, sugar, a pinch of salt, and baking powder if you have it.",
                "Whisk the milk, egg, and melted butter in a second bowl, then fold into the dry mix — lumps are fine.",
                "Heat a lightly buttered skillet over medium; pour 1/4-cup rounds.",
                "Flip when bubbles cover the surface, about 2 minutes; cook 1–2 minutes more.",
                "Stack high and serve with syrup."
            ]
        ),

        UserRecipe(
            id: UUID(uuidString: "A1B2C3D4-0014-4000-8000-000000000014")!,
            title: "Spaghetti & Meat Sauce",
            description: "A hearty, slow-tasting meat sauce that's secretly done in half an hour. The dinner everyone says yes to.",
            cookTime: "30 min", prepTime: "10 min", servings: 4, difficulty: "Easy", cuisine: "Italian",
            tags: ["Starter", "Dinner", "Comfort Food"],
            ingredients: [
                ing("pasta", "12 oz spaghetti"),
                ing("ground beef", "1 lb"),
                ing("tomatoes", "1 can (28 oz), crushed"),
                ing("onion", "1, diced"),
                ing("garlic", "3 cloves, minced"),
                ing("parmesan cheese", "for serving", optional: true),
                ing("basil", "torn, for garnish", optional: true)
            ],
            instructions: [
                "Brown the beef in a wide pan, breaking it up; spoon off excess fat.",
                "Add the onion and cook until soft, then the garlic for 1 minute.",
                "Pour in the tomatoes, season, and simmer 15 minutes while the pasta cooks.",
                "Toss the drained spaghetti with a ladle of sauce, then plate and top with the rest.",
                "Finish with parmesan and basil."
            ]
        )
    ]
}
