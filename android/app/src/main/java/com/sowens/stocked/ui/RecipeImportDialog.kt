package com.sowens.stocked.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import com.sowens.stocked.data.*
import com.sowens.stocked.imports.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun RecipeImportDialog(initialText: String = "", commit: (List<Recipe>) -> Unit, dismiss: () -> Unit) {
    val context=LocalContext.current; val scope=rememberCoroutineScope()
    var text by remember { mutableStateOf(initialText) }; var preview by remember { mutableStateOf<List<Recipe>>(emptyList()) }
    var notice by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }; var error by remember { mutableStateOf<String?>(null) }
    val selected=remember { mutableStateMapOf<String,Boolean>() }
    fun parse(value:String) { scope.launch { busy=true; error=null; try { preview=if(value.trim().startsWith("https://")) RecipeWebFetcher.fetch(value.trim()) else withContext(Dispatchers.Default) { RecipeImporter.parse(value) }; selected.clear(); preview.forEach { selected[it.id]=true } } catch(e:Exception) { error=e.message ?: "Import failed" } finally { busy=false } } }
    val file=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { scope.launch { busy=true; error=null; try { val value=withContext(Dispatchers.IO) { context.contentResolver.openInputStream(it)?.use { input -> val output=java.io.ByteArrayOutputStream(); val buffer=ByteArray(8192); var total=0; while(true) { val read=input.read(buffer); if(read<0) break; total+=read; require(total<=RecipeImporter.MAX_BYTES) { "File exceeds 2 MB." }; output.write(buffer,0,read) }; output.toString("UTF-8") } ?: error("Unable to open file") }; text=value.take(12000); notice=if(value.length>12000) "Large file preview loaded. The text box shows its first 12,000 characters; the recipes below contain all parsed entries." else null; parse(value) } catch(e:Exception) { error=e.message ?: "Unable to read file"; busy=false } } } }
    AlertDialog(onDismissRequest={ if(!busy) dismiss() }, title={ Text("Import recipes") }, text={
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement=Arrangement.spacedBy(8.dp)) {
            Text("Paste a public HTTPS recipe page, Cooklang, or text with Ingredients and Instructions sections. Files can contain JSON or CSV (title, ingredients, instructions, servings). Review before saving.")
            Field("Recipe text or HTTPS URL",text,{ text=it; preview=emptyList() },lines=4)
            OutlinedButton(onClick={ file.launch(arrayOf("application/json","text/*","application/octet-stream")) },enabled=!busy) { Text("Choose file") }
            Button(onClick={ parse(text) },enabled=!busy && text.isNotBlank()) { Text("Preview import") }
            notice?.let { Text(it,style=MaterialTheme.typography.bodySmall) }
            if(busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            error?.let { Text(it,color=MaterialTheme.colorScheme.error) }
            preview.forEach { recipe -> Card { Column(Modifier.padding(12.dp)) {
                Row { Checkbox(selected[recipe.id]==true,{ selected[recipe.id]=it }); Text(recipe.title,style=MaterialTheme.typography.titleMedium) }
                Text("${recipe.servings} servings · ${recipe.ingredients.size} ingredients · ${recipe.instructions.size} steps")
                if (recipe.ingredients.size > 12 || recipe.instructions.size > 8) Text("Preview shows the first 12 ingredients and 8 steps; all entries are saved and editable in the recipe.")
                recipe.ingredients.take(12).forEach { Text("${it.amount} ${it.name}") }; recipe.instructions.take(8).forEachIndexed { i, step -> Text("${i+1}. $step") }
                recipe.sourceURL?.let { Text("Source: $it") }; recipe.license?.let { Text("License: $it") }
                Text("Check quantities and instructions. Importing metadata does not grant redistribution rights.",style=MaterialTheme.typography.bodySmall)
            } } }
        }
    },confirmButton={ TextButton(onClick={ commit(preview.filter { selected[it.id]==true }); dismiss() },enabled=!busy && preview.any { selected[it.id]==true }) { Text("Save selected") } },dismissButton={ TextButton(onClick=dismiss,enabled=!busy) { Text("Cancel") } })
}
