package com.sowens.stocked

import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.sowens.stocked.data.*
import com.sowens.stocked.ui.*
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private var sharedText by mutableStateOf<String?>(null)
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); captureShare(intent) }
    private fun captureShare(intent: Intent?) { if (intent?.action == Intent.ACTION_SEND && intent.type?.startsWith("text/") == true) sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)?.take(2 * 1024 * 1024) }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        captureShare(intent)
        runCatching { CookingTimerStore.restore(applicationContext) }
        val repository = KitchenRepository.get(applicationContext)
        setContent { StockedTheme { StockedApp(repository, sharedText) { sharedText = null } } }
    }
}

@Composable
private fun StockedApp(repository: KitchenRepository, share: String?, clearShare: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current.applicationContext
    val state by repository.state.collectAsStateWithLifecycle()
    var loaded by remember { mutableStateOf(false) }
    var failure by remember { mutableStateOf<String?>(null) }
    var page by remember { mutableIntStateOf(0) }
    var pending by remember { mutableStateOf<Recipe?>(null) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var importing by remember { mutableStateOf(false) }
    var importText by remember { mutableStateOf("") }
    LaunchedEffect(share, loaded) { if (share != null && loaded) { importText = share; importing = true; page = 2; clearShare() } }
    fun report(message: String) { scope.launch { snackbar.showSnackbar(message) } }
    fun operation(block: suspend () -> Unit) { scope.launch { try { block() } catch (error: Exception) { report(error.message ?: "Change could not be saved") } } }
    LaunchedEffect(repository) { try { repository.initialize(); com.sowens.stocked.sync.HouseholdClient.get(context, repository, "https://api.sowensstudios.com/_unified/mobile/stocked/household").startAutomaticSync(); loaded = true } catch (error: Exception) { failure = error.message ?: "Unable to read your kitchen. Existing data has been preserved." } }
    if (importing && loaded) RecipeImportDialog(importText, { recipes -> operation { recipes.forEach { KitchenRules.validate(it) }; repository.importBackup(ImportPreview(KitchenState(userRecipes = recipes), emptyList(), emptyList())); report("${recipes.size} recipes imported") } }, { importing = false })
    val pages = listOf("Pantry", "Groceries", "Recipes", "Plan", "Settings")
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= 700.dp
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }, bottomBar = {
            if (!wide) NavigationBar { pages.forEachIndexed { index, title -> NavigationBarItem(selected = page == index, onClick = { page = index }, icon = { Text(listOf("▦", "✓", "≡", "▤", "⚙")[index]) }, label = { Text(title) }) } }
        }) { padding -> Row(Modifier.fillMaxSize().padding(padding)) {
            if (wide) NavigationRail { Text("Stocked", Modifier.padding(12.dp), style = MaterialTheme.typography.titleMedium); pages.forEachIndexed { index, title -> NavigationRailItem(selected = page == index, onClick = { page = index }, icon = { Text(listOf("▦", "✓", "≡", "▤", "⚙")[index]) }, label = { Text(title) }) } }
            Column(Modifier.weight(1f).fillMaxHeight()) {
                Text("Stocked · ${pages[page]}", Modifier.padding(16.dp), style = MaterialTheme.typography.headlineSmall)
                when {
                    failure != null -> EmptyState("Kitchen data needs attention", failure!! + " Export or recover the original data before clearing app storage.")
                    !loaded -> Column(Modifier.padding(24.dp)) { CircularProgressIndicator(); Text("Opening your kitchen…") }
                    else -> when (page) {
                        0 -> InventoryScreen(state, { operation { repository.upsertInventory(it) } }, { operation { repository.deleteInventory(it) } }, { id, amount -> operation { repository.consume(id, amount) } })
                        1 -> GroceryScreen(state, { operation { repository.upsertGrocery(it) } }, { operation { repository.deleteGrocery(it) } }, { operation { repository.toggleGrocery(it) } })
                        2 -> RecipeScreen(state, { operation { repository.upsertRecipe(it) } }, { operation { repository.deleteRecipe(it) } }, { operation { repository.addRecipeGroceries(it); report("Recipe ingredients added to groceries") } }, { id, amount -> operation { repository.consume(id, amount) } }, { pending = it; page = 3 }, { importText = ""; importing = true })
                        3 -> MealScreen(state, pending, { pending = null }, { operation { repository.upsertMeal(it) } }, { operation { repository.deleteMeal(it) } }, { operation { repository.addMealGroceries(it); report("Meal ingredients added to groceries") } }, { operation { repository.completeMeal(it) } })
                        4 -> SettingsScreen(repository, state, ::report)
                    }
                }
            }
        } }
    }
}
