package com.sowens.stocked.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.sowens.stocked.scan.ScanScreen
import com.sowens.stocked.sync.HouseholdClient
import com.sowens.stocked.data.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun SettingsScreen(repository: KitchenRepository, state: KitchenState, report: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var preview by remember { mutableStateOf<ImportPreview?>(null) }
    var replace by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var scan by remember { mutableStateOf(false) }
    var household by remember { mutableStateOf(false) }
    val householdClient = remember(repository) { HouseholdClient.get(context.applicationContext, repository, "https://api.sowensstudios.com/_unified/mobile/stocked/household") }
    if (scan) Dialog(onDismissRequest = { scan = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) { Surface(Modifier.fillMaxSize()) { ScanScreen(repository, report) { scan = false } } }
    if (household) Dialog(onDismissRequest = { household = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) { Surface(Modifier.fillMaxSize()) { Column(Modifier.fillMaxSize()) { TextButton(onClick = { household = false }) { Text("Back to settings") }; HouseholdScreen(householdClient) } } }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri -> uri?.let { scope.launch {
        busy = true
        try { val backup = repository.exportBackup(); withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(it, "wt")?.use { output -> output.write(backup.toByteArray(Charsets.UTF_8)) } ?: error("Unable to open selected file") }; report("Backup exported") } catch (error: Exception) { report(error.message ?: "Backup export failed") } finally { busy = false }
    } } }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { scope.launch {
        busy = true
        try { val text = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(it)?.use { input -> val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192); var total = 0; while (true) { val count = input.read(buffer); if (count < 0) break; total += count; require(total <= 20 * 1024 * 1024) { "Backup exceeds 20 MB" }; output.write(buffer, 0, count) }; output.toString("UTF-8") } ?: error("Unable to open selected file") }; preview = repository.previewBackup(text); replace = false } catch (error: Exception) { report(error.message ?: "Backup import failed") } finally { busy = false }
    } } }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Your kitchen, on your device", style = MaterialTheme.typography.headlineSmall)
        Button(onClick = { scan = true }) { Text("Scan food or receipt") }
        OutlinedButton(onClick = { household = true }) { Text("Household sync") }
        Text("${state.inventory.size} inventory entries · ${state.grocery.size} groceries · ${state.userRecipes.size} recipes · ${state.planned.size} meals")
        Text("Data is saved internally after each change. Export a backup before clearing application data or moving devices.")
        Button(onClick = { export.launch("Stocked-backup-${java.time.LocalDate.now()}.json") }, enabled = !busy) { Text("Export backup") }
        OutlinedButton(onClick = { import.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }, enabled = !busy) { Text("Import backup") }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        Text("This Android edition supports offline kitchen tools. Import structured recipe websites, JSON, CSV, Cooklang or text from Recipes. Use Household sync to join and exchange kitchen data. Platform widgets are not available in this edition.", style = MaterialTheme.typography.bodyMedium)
    }
    preview?.let { data -> AlertDialog(onDismissRequest = { if (!busy) preview = null }, title = { Text("Review backup import") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("${data.incoming.inventory.size} inventory entries, ${data.incoming.grocery.size} groceries, ${data.incoming.userRecipes.size} recipes, ${data.incoming.planned.size} meals")
            Text("${data.conflicts.size} existing IDs overlap. New entries will be merged; unrelated local entries remain.")
            data.warnings.forEach { Text(it, color = MaterialTheme.colorScheme.error) }
            Row { Checkbox(checked = replace, onCheckedChange = { replace = it }); Text("Replace overlapping entries with imported values") }
        }
    }, confirmButton = { TextButton(enabled = !busy, onClick = { scope.launch { busy = true; try { repository.importBackup(data, replace); preview = null; report("Backup imported") } catch (error: Exception) { report(error.message ?: "Import failed") } finally { busy = false } } }) { Text("Import") } }, dismissButton = { TextButton(onClick = { preview = null }, enabled = !busy) { Text("Cancel") } }) }
}
