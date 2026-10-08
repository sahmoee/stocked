package com.sowens.stocked

import android.os.Bundle
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.sowens.stocked.scan.ScanScreen
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
    var settingsOpen by remember { mutableStateOf(false) }
    var scanning by remember { mutableStateOf(false) }
    var searching by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var filteredQuery by remember { mutableStateOf("") }
    var filteredPage by remember { mutableIntStateOf(-1) }
    var importing by remember { mutableStateOf(false) }
    var importText by remember { mutableStateOf("") }
    LaunchedEffect(share, loaded) { if (share != null && loaded) { importText = share; importing = true; page = 3; clearShare() } }
    fun report(message: String) { scope.launch { snackbar.showSnackbar(message) } }
    fun operation(block: suspend () -> Unit) { scope.launch { try { block() } catch (error: Exception) { report(error.message ?: "Change could not be saved") } } }
    LaunchedEffect(repository) { try { repository.initialize(); com.sowens.stocked.sync.HouseholdClient.get(context, repository, "https://api.sowensstudios.com/_unified/mobile/stocked/household").startAutomaticSync(); loaded = true } catch (error: Exception) { failure = error.message ?: "Unable to read your kitchen. Existing data has been preserved." } }
    if (importing && loaded) RecipeImportDialog(importText, { recipes -> operation { recipes.forEach { KitchenRules.validate(it) }; repository.importBackup(ImportPreview(KitchenState(userRecipes = recipes), emptyList(), emptyList())); report("${recipes.size} recipes imported") } }, { importing = false })
    val pages = listOf("Home", "Cook", "Kitchen", "Recipes", "Grocery")
    if (settingsOpen) Dialog(onDismissRequest={ settingsOpen=false },properties=DialogProperties(usePlatformDefaultWidth=false)) { Surface(Modifier.fillMaxSize()) { Column { TextButton(onClick={ settingsOpen=false }) { Text("Back to Stocked") }; SettingsScreen(repository,state,::report) } } }
    if (scanning) Dialog(onDismissRequest={ scanning=false },properties=DialogProperties(usePlatformDefaultWidth=false)) { Surface(Modifier.fillMaxSize()) { ScanScreen(repository,::report) { scanning=false } } }
    if (searching) AlertDialog(onDismissRequest={ searching=false },title={ Text("Search your kitchen") },text={ Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        Field("Food, recipe or grocery",search,{ search=it })
        if (search.isNotBlank()) {
            listOf(2 to state.inventory.filter { it.name.contains(search,true) }.map { it.name }, 3 to state.userRecipes.filter { it.title.contains(search,true) }.map { it.title }, 4 to state.grocery.filter { it.name.contains(search,true) }.map { it.name }).forEach { (destination,names) -> names.take(4).forEach { name -> TextButton(onClick={ filteredQuery=search; filteredPage=destination; page=destination; searching=false }) { Text("$name · ${pages[destination]}") } } }
        }
    } },confirmButton={ TextButton(onClick={ searching=false }) { Text("Done") } })
    Scaffold(snackbarHost={ SnackbarHost(snackbar) }, bottomBar={ StockedBottomNav(page) { page=it; filteredPage=-1 } }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding),contentAlignment=Alignment.TopCenter) {
            Column(Modifier.widthIn(max=1040.dp).fillMaxSize()) {
                Row(Modifier.fillMaxWidth().padding(horizontal=20.dp).heightIn(min=60.dp),verticalAlignment=Alignment.CenterVertically) {
                    Row(Modifier.weight(1f),verticalAlignment=Alignment.Bottom) { Text("Stocked",fontFamily=FontFamily.Serif,fontWeight=FontWeight.Bold,fontSize=40.sp,letterSpacing=(-1).sp); Text(".",color=StockedPalette.honey,fontFamily=FontFamily.Serif,fontWeight=FontWeight.Bold,fontSize=40.sp) }
                    IconButton(onClick={ searching=true }) { Icon(Icons.Outlined.Search,"Search everything") }
                    IconButton(onClick={ settingsOpen=true }) { Icon(Icons.Outlined.Settings,"Settings") }
                }
                when {
                    failure != null -> EmptyState("Kitchen data needs attention",failure!! + " Export or recover the original data before clearing app storage.")
                    !loaded -> Column(Modifier.padding(24.dp)) { CircularProgressIndicator(); Text("Opening your kitchen…") }
                    else -> when(page) {
                        0 -> HomeScreen(state,{ page=it },{ scanning=true })
                        1 -> MealScreen(state,pending,{ pending=null },{ operation { repository.upsertMeal(it) } },{ operation { repository.deleteMeal(it) } },{ operation { repository.addMealGroceries(it); report("Meal ingredients added to groceries") } },{ operation { repository.completeMeal(it) } },{ page=3 })
                        2 -> InventoryScreen(state,{ operation { repository.upsertInventory(it) } },{ operation { repository.deleteInventory(it) } },{ id,amount -> operation { repository.consume(id,amount) } },if(filteredPage==2) filteredQuery else "")
                        3 -> RecipeScreen(state,{ operation { repository.upsertRecipe(it) } },{ operation { repository.deleteRecipe(it) } },{ operation { repository.addRecipeGroceries(it); report("Recipe ingredients added to groceries") } },{ id,amount -> operation { repository.consume(id,amount) } },{ pending=it; page=1 },{ importText=""; importing=true },if(filteredPage==3) filteredQuery else "")
                        4 -> GroceryScreen(state,{ operation { repository.upsertGrocery(it) } },{ operation { repository.deleteGrocery(it) } },{ operation { repository.toggleGrocery(it) } },if(filteredPage==4) filteredQuery else "")
                    }
                }
            }
        }
    }
}

@Composable private fun StockedBottomNav(selected:Int,select:(Int)->Unit) {
    val labels=listOf("Home","Cook","Kitchen","Recipes","Grocery")
    val icons=listOf(Icons.Outlined.Home,Icons.Outlined.Restaurant,Icons.Outlined.Kitchen,Icons.Outlined.MenuBook,Icons.Outlined.ShoppingCart)
    Surface(color=MaterialTheme.colorScheme.background) { Column(Modifier.navigationBarsPadding()) {
        HorizontalDivider(thickness=0.65.dp,color=MaterialTheme.colorScheme.outlineVariant)
        Row(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=4.dp),horizontalArrangement=Arrangement.Center) {
            labels.forEachIndexed { index,label ->
                val active=selected==index
                val ink=if(active) StockedPalette.accent() else MaterialTheme.colorScheme.onSurfaceVariant
                Column(Modifier.weight(1f).selectable(selected=active,onClick={ select(index) }).heightIn(min=58.dp).padding(vertical=6.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(3.dp)) {
                    Icon(icons[index],contentDescription=null,tint=ink,modifier=Modifier.size(23.dp))
                    Text(label,color=ink,style=MaterialTheme.typography.labelSmall,fontWeight=if(active) FontWeight.SemiBold else FontWeight.Normal)
                }
            }
        }
    } }
}
