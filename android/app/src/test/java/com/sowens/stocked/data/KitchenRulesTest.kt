package com.sowens.stocked.data

import org.junit.Assert.*
import org.junit.Test

class KitchenRulesTest {
 @Test fun exactDedupPreservesIdentityAndCheckedRows() {
  val first=GroceryItem(name="  MILK ",quantity=2)
  val checked=GroceryItem(name="milk",isChecked=true)
  val result=KitchenRules.addGrocery(listOf(first,checked),GroceryItem(name="milk",quantity=3))
  assertEquals(2,result.size); assertEquals(first.id,result.first().id); assertEquals(5,result.first().quantity)
  assertEquals(3,KitchenRules.addGrocery(result,GroceryItem(name="milk",sizeText="1 litre")).size)
 }
 @Test fun consumptionCannotOverdraw() {
  val row=InventoryItem(name="Beans",quantity=3)
  assertEquals(1,KitchenRules.consume(row,2,42.0).quantity)
  assertTrue(runCatching{KitchenRules.consume(row,4,42.0)}.isFailure)
 }
 @Test fun validationRejectsBadDateAndNonfiniteQuantity() {
  assertTrue(runCatching{KitchenRules.validate(InventoryItem(name="Eggs",expirationDate="2026-02-31"))}.isFailure)
  assertTrue(runCatching{KitchenRules.validate(InventoryItem(name="Eggs",sizeAmount=Double.NaN))}.isFailure)
 }
 @Test fun backupRoundTripPreservesIdsAndUnknownSections() {
  val item=InventoryItem(name="Eggs",quantity=2,expirationDate="2026-10-09")
  val state=KitchenState(inventory=listOf(item))
  val parsed=BackupCodec.preview(BackupCodec.export(state),KitchenState())
  assertEquals(item.id,parsed.incoming.inventory.single().id)
  assertEquals(item.expirationDate,parsed.incoming.inventory.single().expirationDate)
 }
 @Test fun importConflictPreservesLocalByDefault() {
  val local=InventoryItem(name="Eggs",quantity=2)
  val incoming=local.copy(quantity=9)
  val existing=KitchenState(inventory=listOf(local))
  val imported=KitchenState(inventory=listOf(incoming))
  assertEquals(2,BackupCodec.merge(existing,imported,false).inventory.single().quantity)
  assertEquals(9,BackupCodec.merge(existing,imported,true).inventory.single().quantity)
 }
 @Test fun encryptedAndDuplicateBackupsRefused() {
  assertTrue(runCatching{BackupCodec.preview("{\"sealedPayload\":\"abc\"}",KitchenState())}.isFailure)
  val row=InventoryItem(name="Eggs")
  assertTrue(runCatching{BackupCodec.preview(BackupCodec.export(KitchenState(inventory=listOf(row,row))),KitchenState())}.isFailure)
 }
 @Test fun iosAliasesAndUnknownFieldsPreserved() {
  val text="""{"schemaVersion":3,"inventoryItems":[{"id":"00000000-0000-0000-0000-000000000001","name":"Milk","expirationDate":"2026-10-10T00:00:00Z","nutrition":{"calories":100}}],"features":{"saved":true}}"""
  val preview=BackupCodec.preview(text,KitchenState())
  assertEquals("2026-10-10",preview.incoming.inventory.single().expirationDate)
  val exported=BackupCodec.export(preview.incoming)
  assertTrue(exported.contains("nutrition")); assertTrue(exported.contains("features"))
 }
}
