package com.sowens.stocked.data

import android.content.Context
import android.util.AtomicFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import java.io.File

/** Publish only after fsync/atomic commit. Failed writes preserve both the previous disk and UI state. */
class KitchenRepository private constructor(context:Context) {
 companion object {
  @Volatile private var instance:KitchenRepository?=null
  fun get(context:Context):KitchenRepository=instance ?: synchronized(this){instance ?: KitchenRepository(context.applicationContext).also{instance=it}}
 }
 private val mutableLocalChanges=MutableStateFlow(0L)
 val localChanges:StateFlow<Long> = mutableLocalChanges.asStateFlow()
 private val file=AtomicFile(File(context.filesDir,"kitchen-v1.json"))
 private val mutex=Mutex()
 private val mutableState=MutableStateFlow(KitchenState())
 val state:StateFlow<KitchenState> = mutableState.asStateFlow()
 private val mutableError=MutableStateFlow<String?>(null)
 val error:StateFlow<String?> = mutableError.asStateFlow()
 private var initialized=false
 suspend fun initialize() = withContext(Dispatchers.IO) { mutex.withLock {
  if(initialized)return@withLock
  try {
   if(file.baseFile.exists() || File(file.baseFile.path+".bak").exists()) {
    require(file.baseFile.length() <= 20*1024*1024) { "Kitchen data exceeds the safe load limit." }
    mutableState.value=BackupCodec.json.decodeFromString<KitchenState>(file.openRead().bufferedReader().use{it.readText()})
   }
   initialized=true
  } catch(e:Exception) { mutableError.value="Stored kitchen could not be read. Your file has been preserved. ${e.message}"; throw e }
 } }
 private suspend fun mutate(notifyLocal:Boolean=true,transform:(KitchenState)->KitchenState) = withContext(Dispatchers.IO) { mutex.withLock {
  check(initialized) { "Kitchen is still loading." }
  val next=transform(mutableState.value)
  val bytes=BackupCodec.json.encodeToString(next).toByteArray(Charsets.UTF_8)
  require(bytes.size <= 20*1024*1024) { "Kitchen data exceeds the safe storage limit." }
  var output:java.io.FileOutputStream?=null
  try { output=file.startWrite(); output.write(bytes); file.finishWrite(output); mutableState.value=next; if(notifyLocal)mutableLocalChanges.value+=1; mutableError.value=null }
  catch(e:Exception) { if(output!=null)file.failWrite(output); mutableError.value="Changes were not saved: ${e.message}"; throw e }
 } }
 /** Remote/journal mutation: must never trigger an automatic upload loop. */
 suspend fun transformState(transform:(KitchenState)->KitchenState)=mutate(notifyLocal=false,transform=transform)
 /** One durable local receipt transaction and one local-change notification. */
 suspend fun addInventoryBatch(items:List<InventoryItem>) {
  mutate { state -> LocalInventoryBatch.apply(state,items,now()) }
 }
 private fun now()=System.currentTimeMillis().toDouble()
 private fun <T> upsert(values:List<T>, item:T, id:(T)->String):List<T> = if(values.any{id(it)==id(item)})values.map{if(id(it)==id(item))item else it} else values+item
 suspend fun upsertInventory(item:InventoryItem) { KitchenRules.validate(item); mutate{it.copy(inventory=upsert(it.inventory,item.copy(name=item.name.trim(),updatedAt=now())){a->a.id})} }
 suspend fun upsertGrocery(item:GroceryItem) { KitchenRules.validate(item); mutate{state->state.copy(grocery=if(state.grocery.any{it.id==item.id})upsert(state.grocery,item.copy(name=item.name.trim(),updatedAt=now())){it.id} else KitchenRules.addGrocery(state.grocery,item.copy(name=item.name.trim(),updatedAt=now())))} }
 suspend fun upsertRecipe(item:Recipe) { KitchenRules.validate(item); mutate{it.copy(userRecipes=upsert(it.userRecipes,item.copy(title=item.title.trim(),updatedAt=now())){a->a.id})} }
 suspend fun upsertMeal(item:PlannedMeal) { KitchenRules.validate(item); mutate{it.copy(planned=upsert(it.planned,item.copy(title=item.title.trim(),updatedAt=now())){a->a.id})} }
 suspend fun deleteInventory(id:String)=mutate{it.copy(inventory=it.inventory.filterNot{row->row.id==id})}
 suspend fun deleteGrocery(id:String)=mutate{it.copy(grocery=it.grocery.filterNot{row->row.id==id})}
 suspend fun deleteRecipe(id:String)=mutate{it.copy(userRecipes=it.userRecipes.filterNot{row->row.id==id})}
 suspend fun deleteMeal(id:String)=mutate{it.copy(planned=it.planned.filterNot{row->row.id==id})}
 suspend fun toggleGrocery(id:String)=mutate{it.copy(grocery=it.grocery.map{row->if(row.id==id)row.copy(isChecked=!row.isChecked,updatedAt=now())else row})}
 suspend fun consume(id:String,quantity:Int)=mutate{state->
  val item=state.inventory.find{it.id==id} ?: error("Inventory item no longer exists.")
  val next=KitchenRules.consume(item,quantity,now())
  state.copy(inventory=state.inventory.map{if(it.id==id)next else it})
 }
 suspend fun completeMeal(id:String)=mutate{it.copy(planned=it.planned.map{row->if(row.id==id)row.copy(isCooked=true,updatedAt=now())else row})}
 suspend fun addRecipeGroceries(id:String)=mutate{state->
  val recipe=state.userRecipes.find{it.id==id} ?: error("Recipe no longer exists.")
  state.copy(grocery=KitchenRules.recipeGroceries(recipe,now()).fold(state.grocery){all,row->KitchenRules.addGrocery(all,row)})
 }
 suspend fun addMealGroceries(id:String)=mutate{state->
  val meal=state.planned.find{it.id==id} ?: error("Meal no longer exists.")
  val rows=meal.ingredients.filter{it.isNotBlank()}.map{GroceryItem(name=it,recipeSource=meal.title,recipeId=meal.id,updatedAt=now())}
  state.copy(grocery=rows.fold(state.grocery){all,row->KitchenRules.addGrocery(all,row)})
 }
 suspend fun exportBackup():String = withContext(Dispatchers.IO){BackupCodec.export(state.value)}
 suspend fun previewBackup(text:String):ImportPreview = withContext(Dispatchers.IO){BackupCodec.preview(text,state.value)}
 suspend fun importBackup(preview:ImportPreview,replaceExisting:Boolean=false)=mutate{BackupCodec.merge(it,preview.incoming,replaceExisting)}
}

/** Pure receipt transaction preparation; validation finishes before any item is appended. */
object LocalInventoryBatch {
 fun apply(state:KitchenState,items:List<InventoryItem>,timestamp:Double):KitchenState {
  require(items.size <= 200) { "Review at most 200 items at a time." }
  items.forEach(KitchenRules::validate)
  require(items.map{it.id}.distinct().size==items.size) { "Receipt contains duplicate IDs." }
  require(items.none{item->state.inventory.any{it.id==item.id}}) { "Receipt item already exists; no items were added." }
  return state.copy(inventory=state.inventory+items.map{it.copy(name=it.name.trim(),updatedAt=timestamp)})
 }
}
