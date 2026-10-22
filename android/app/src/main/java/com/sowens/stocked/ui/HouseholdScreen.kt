package com.sowens.stocked.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sowens.stocked.sync.HouseholdClient
import kotlinx.coroutines.launch

@Composable fun HouseholdScreen(client:HouseholdClient) {
 val scope=rememberCoroutineScope();val message by client.message.collectAsState()
 var name by remember{mutableStateOf("")};var code by remember{mutableStateOf("")};var busy by remember{mutableStateOf(false)};var confirmLeave by remember{mutableStateOf(false)}
 fun perform(work:suspend ()->Unit){scope.launch{busy=true;try{work()}catch(_:Exception){}finally{busy=false}}}
 Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
  Text("Shared kitchen",style=MaterialTheme.typography.headlineSmall)
  Text("Sync inventory, groceries, recipes and meal plans with your household. Offline changes sync automatically when connected. Background checks run about every 15 minutes; Android may delay them. Tap Sync now for an immediate check.")
  if(client.code().isEmpty()) {
   OutlinedTextField(value=name,onValueChange={name=it.take(60)},label={Text("Your name")},singleLine=true,modifier=Modifier.fillMaxWidth())
   Button(enabled=!busy && name.isNotBlank(),onClick={perform{client.enroll(name)}}){Text("Create household")}
   OutlinedTextField(value=code,onValueChange={code=it.take(2048)},label={Text("Household code or invitation link")},modifier=Modifier.fillMaxWidth())
   OutlinedButton(enabled=!busy && name.isNotBlank() && code.isNotBlank(),onClick={perform{client.enroll(name,code)}}){Text("Join household")}
  } else {
   Text("Household: ${client.code()} · ${client.role()}")
   Button(enabled=!busy,onClick={perform{client.sync()}}){Text("Sync now")}
   OutlinedButton(enabled=!busy,onClick={confirmLeave=true}){Text("Leave household")}
  }
  if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
  Text(message)
  Text("Membership credentials are encrypted with this device’s Android Keystore and excluded from backups. Keep an exported kitchen backup before clearing app data.",style=MaterialTheme.typography.bodySmall)
 }
 if(confirmLeave)AlertDialog(onDismissRequest={confirmLeave=false},title={Text("Leave household?")},text={Text("Your local kitchen remains. This device loses household access. Pending changes must be synced first.")},confirmButton={TextButton(onClick={confirmLeave=false;perform{client.leave()}}){Text("Leave")}},dismissButton={TextButton(onClick={confirmLeave=false}){Text("Cancel")}})
}
