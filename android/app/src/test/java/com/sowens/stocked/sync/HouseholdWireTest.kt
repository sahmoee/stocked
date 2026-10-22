package com.sowens.stocked.sync
import kotlinx.serialization.json.*
import org.junit.Test
import org.junit.Assert.*
class HouseholdWireTest {
 private fun doc(quantity:Int,name:String="Milk")=buildJsonObject{put("inventory",buildJsonArray{add(buildJsonObject{put("id","a");put("name",name);put("quantity",quantity)})})}
 @Test fun quantityUpdateUsesBaselineAndDurableKeys(){val batch=HouseholdWire.batch(doc(5),doc(3),8);assertEquals(-2,batch.getValue("quantityOperations").jsonArray.single().jsonObject.getValue("delta").jsonPrimitive.int);assertEquals(5,batch.getValue("inventory").jsonArray.single().jsonObject.getValue("quantity").jsonPrimitive.int);assertEquals(batch,Json.parseToJsonElement(batch.toString()))}
 @Test fun acknowledgeDoesNotReapplyAlreadySentQuantity(){val merged=HouseholdWire.merge(doc(3),doc(3),doc(2));assertEquals(2,HouseholdWire.rows(merged,"inventory").getValue("a").getValue("quantity").jsonPrimitive.int)}
 @Test fun editsMadeDuringFlightAreRetained(){val merged=HouseholdWire.merge(doc(3),doc(3,"Local edit"),doc(2));assertEquals("Local edit",HouseholdWire.rows(merged,"inventory").getValue("a").getValue("name").jsonPrimitive.content)}
 @Test fun unchangedRecordHonorsServerTombstone(){val remote=buildJsonObject{put("inventory",JsonArray(emptyList()));put("invDeleted",buildJsonArray{add("a")})};assertTrue(HouseholdWire.rows(HouseholdWire.merge(doc(5),doc(5),remote),"inventory").isEmpty())}
 @Test fun batchLimitKeepsUnsentRecordsInNextDiff(){val base=buildJsonObject{put("inventory",JsonArray(emptyList()))};val current=buildJsonObject{put("inventory",buildJsonArray{repeat(201){i->add(buildJsonObject{put("id","item-$i");put("name","Milk");put("quantity",1)})}})};val first=HouseholdWire.batch(base,current,1);assertEquals(200,first.getValue("operations").jsonArray.size);val snapshot=HouseholdWire.sentSnapshot(base,current,first);assertEquals(1,HouseholdWire.batch(snapshot,current,2).getValue("operations").jsonArray.size)}
 @Test fun membershipJournalDoesNotExport(){val state=com.sowens.stocked.data.KitchenState(extra=buildJsonObject{put("_androidHousehold",buildJsonObject{put("code","PRIVATE")});put("iosSetting",true)});val exported=com.sowens.stocked.data.BackupCodec.export(state);assertFalse(exported.contains("PRIVATE"));assertTrue(exported.contains("iosSetting"))}
 @Test fun offlineDeleteSurvivesRemotePull(){val empty=buildJsonObject{put("inventory",JsonArray(emptyList()))};val merged=HouseholdWire.merge(doc(5),empty,doc(7));assertTrue(HouseholdWire.rows(merged,"inventory").isEmpty());assertEquals("delete",HouseholdWire.batch(doc(5),empty,1).getValue("operations").jsonArray.single().jsonObject.getValue("operationType").jsonPrimitive.content)}
 @Test fun androidZonesUseReleasedIOSWireKey(){
  for(zone in listOf("Fridge","Freezer","Pantry","Staples")) {
   val state=com.sowens.stocked.data.KitchenState(inventory=listOf(com.sowens.stocked.data.InventoryItem(name="Milk",storageCategory=zone)))
   val row=HouseholdWire.document(state).getValue("inventory").jsonArray.single().jsonObject
   assertEquals(zone,row.getValue("zone").jsonPrimitive.content);assertFalse(row.containsKey("storageCategory"))
  }
 }
 @Test fun iosZoneImportsWithoutChangingStorageOrUnknownMetadata(){
  val id="00000000-0000-0000-0000-000000000001"
  val remote=buildJsonObject{put("inventory",buildJsonArray{add(buildJsonObject{put("id",id);put("name","Milk");put("quantity",2);put("zone","Fridge");put("futureField","preserved")})})}
  val kitchen=HouseholdWire.kitchen(remote,com.sowens.stocked.data.KitchenState())
  assertEquals("Fridge",kitchen.inventory.single().storageCategory)
  val roundTrip=HouseholdWire.document(kitchen).getValue("inventory").jsonArray.single().jsonObject
  assertEquals("Fridge",roundTrip.getValue("zone").jsonPrimitive.content);assertEquals("preserved",roundTrip.getValue("futureField").jsonPrimitive.content)
 }
 @Test fun androidRecipesAndMealsSupplyRequiredIOSCodableFields(){
  val state=com.sowens.stocked.data.KitchenState(userRecipes=listOf(com.sowens.stocked.data.Recipe(title="Soup",ingredients=listOf(com.sowens.stocked.data.Ingredient(name="Beans")),instructions=listOf("Cook"),updatedAt=1780000000000.0)),planned=listOf(com.sowens.stocked.data.PlannedMeal(title="Soup")))
  val wire=HouseholdWire.document(state)
  val recipe=wire.getValue("userRecipes").jsonArray.single().jsonObject
  assertEquals("Medium",recipe.getValue("difficulty").jsonPrimitive.content)
  assertEquals("unspecified",recipe.getValue("dishRole").jsonPrimitive.content)
  assertEquals(801692800.0,recipe.getValue("dateCreated").jsonPrimitive.double,0.01)
  assertFalse(recipe.getValue("ingredients").jsonArray.single().jsonObject.getValue("isOptional").jsonPrimitive.boolean)
  val meal=wire.getValue("plannedMeals").jsonArray.single().jsonObject
  assertFalse(meal.getValue("isBuilding").jsonPrimitive.boolean);assertEquals("none",meal.getValue("cookAheadStatus").jsonPrimitive.content)
 }
 @Test fun byteBoundedBatchKeepsUnsentRowsForNextBatch(){
  val base=buildJsonObject{put("userRecipes",JsonArray(emptyList()))}
  val current=buildJsonObject{put("userRecipes",buildJsonArray{repeat(3){i->add(buildJsonObject{put("id","recipe-$i");put("title","Soup");put("notes","🍲".repeat(200000))})}})}
  val batch=HouseholdWire.batch(base,current,1)
  assertEquals(2,batch.getValue("operations").jsonArray.size)
  assertTrue(batch.toString().toByteArray(Charsets.UTF_8).size<=HouseholdWire.MAX_BATCH_BYTES)
  val snapshot=HouseholdWire.sentSnapshot(base,current,batch)
  assertEquals(1,HouseholdWire.batch(snapshot,current,2).getValue("operations").jsonArray.size)
  assertEquals(batch,Json.parseToJsonElement(batch.toString()))
 }
 @Test fun oversizedSingleRecordFailsBeforeFreezingOrLosingData(){
  val empty=JsonObject(emptyMap());val large=buildJsonObject{put("userRecipes",buildJsonArray{add(buildJsonObject{put("id","huge");put("title","Soup");put("notes","x".repeat(HouseholdWire.MAX_BATCH_BYTES))})})}
  val error=runCatching{HouseholdWire.batch(empty,large,1)}.exceptionOrNull()
  assertTrue(error is IllegalArgumentException);assertTrue(error!!.message!!.contains("Local data has been retained"))
  assertEquals(1,HouseholdWire.rows(large,"userRecipes").size)
 }

 @Test fun canonicalBackupFeedsAllReleasedHouseholdCollections() {
  val text=javaClass.getResource("/backup/ios-canonical.json")!!.readText()
  val state=com.sowens.stocked.data.BackupCodec.preview(text,com.sowens.stocked.data.KitchenState()).incoming
  val wire=HouseholdWire.document(state)
  val expected=listOf(state.inventory.single().id,state.grocery.single().id,state.userRecipes.single().id,state.planned.single().id)
  HouseholdWire.collections.zip(expected).forEach { (collection,id) ->
   assertEquals(id,wire.getValue(collection.key).jsonArray.single().jsonObject.getValue("id").jsonPrimitive.content)
  }
  assertFalse(wire.containsKey("inventoryItems"));assertFalse(wire.containsKey("groceryItems"));assertFalse(wire.containsKey("planned"))
  val inventory=wire.getValue("inventory").jsonArray.single().jsonObject
  assertEquals("Fridge",inventory.getValue("zone").jsonPrimitive.content)
  assertEquals(3,inventory.getValue("quantity").jsonPrimitive.int)
  assertEquals(java.time.Instant.ofEpochSecond(1778307200,125000000).toString(),inventory.getValue("expirationDate").jsonPrimitive.content)
  assertEquals(1770000000123.0,inventory.getValue("updatedAt").jsonPrimitive.double,0.0)
  val restored=HouseholdWire.kitchen(wire,state)
  assertEquals(state.inventory.single().id,restored.inventory.single().id)
  assertEquals(state.inventory.single().expirationDate,restored.inventory.single().expirationDate)
  assertEquals(state.grocery.single().isChecked,restored.grocery.single().isChecked)
  assertEquals(state.userRecipes.single().id,restored.userRecipes.single().id)
  assertEquals(state.planned.single().isCooked,restored.planned.single().isCooked)
  assertEquals(state.extra,restored.extra)
 }
 @Test fun nonemptyHouseholdRoundTripPreservesUnknownFieldsAndKnownDates() {
  val inventory=com.sowens.stocked.data.InventoryItem(id="00000000-0000-0000-0000-000000000001",name="Milk",quantity=3,storageCategory="Fridge",expirationDate="2026-10-22",updatedAt=1770000000123.0,extra=buildJsonObject{put("nutrition",buildJsonObject{put("calories",100)})})
  val grocery=com.sowens.stocked.data.GroceryItem(id="00000000-0000-0000-0000-000000000002",name="Rice",quantity=4,isChecked=true,extra=buildJsonObject{put("assignedTo","synthetic-member")})
  val recipe=com.sowens.stocked.data.Recipe(id="00000000-0000-0000-0000-000000000003",title="Soup",isFavorited=true,ingredients=listOf(com.sowens.stocked.data.Ingredient(id="00000000-0000-0000-0000-000000000004",name="Milk",amount="1 cup",extra=buildJsonObject{put("isOptional",true);put("futureIngredient",42)})),extra=buildJsonObject{put("dateCreated",700000000.125);put("lastCooked",750000000.25);put("futureRecipe",true)})
  val plan=com.sowens.stocked.data.PlannedMeal(id="00000000-0000-0000-0000-000000000005",title="Soup",servings=2,ingredients=listOf("Milk"),isCooked=true,extra=buildJsonObject{put("isBuilding",true);put("cookAheadStatus","stored");put("futurePlan","kept")})
  val state=com.sowens.stocked.data.KitchenState(inventory=listOf(inventory),grocery=listOf(grocery),userRecipes=listOf(recipe),planned=listOf(plan),extra=buildJsonObject{put("localOnlySetting",true)})
  val first=HouseholdWire.document(state)
  val restored=HouseholdWire.kitchen(first,state)
  val second=HouseholdWire.document(restored)
  HouseholdWire.collections.forEach { collection ->
   assertEquals(1,first.getValue(collection.key).jsonArray.size)
   assertEquals(first.getValue(collection.key),second.getValue(collection.key))
  }
  assertEquals(3,restored.inventory.single().quantity);assertEquals("2026-10-22",restored.inventory.single().expirationDate)
  assertEquals(4,restored.grocery.single().quantity);assertTrue(restored.grocery.single().isChecked)
  assertTrue(restored.userRecipes.single().isFavorited);assertTrue(restored.planned.single().isCooked)
  assertEquals(700000000.125,second.getValue("userRecipes").jsonArray.single().jsonObject.getValue("dateCreated").jsonPrimitive.double,0.0)
  assertEquals(750000000.25,second.getValue("userRecipes").jsonArray.single().jsonObject.getValue("lastCooked").jsonPrimitive.double,0.0)
  assertEquals(state.extra,restored.extra)
 }

}
