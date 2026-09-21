import Foundation

@main struct InventoryFormPolicyChecks {
    static func main() {
        precondition(InventoryFormPolicy.normalizedName(" \n\t Milk \r\n") == "Milk")
        precondition(InventoryFormPolicy.normalizedName(" \n\t ").isEmpty)
        precondition(InventoryFormPolicy.normalizedName("Crème fraîche") == "Crème fraîche")
        precondition(InventoryFormPolicy.storageSelection(current: "Freezer", suggested: "Fridge", manuallySelected: true) == "Freezer")
        precondition(InventoryFormPolicy.storageSelection(current: "Freezer", suggested: "Fridge", manuallySelected: false) == "Fridge")
        precondition(InventoryFormPolicy.editableQuantity(0) == 0)
        precondition(InventoryFormPolicy.editableQuantity(-3) == 0)
        precondition(InventoryFormPolicy.editableQuantity(8) == 8)
        precondition(InventoryFormPolicy.editableFillLevel(0) == 0)
        precondition(InventoryFormPolicy.editableFillLevel(.nan) == 0)
        precondition(InventoryFormPolicy.editableFillLevel(.infinity) == 0)
        precondition(InventoryFormPolicy.editableFillLevel(-.infinity) == 0)
        precondition(InventoryFormPolicy.editableFillLevel(-0.2) == 0)
        precondition(InventoryFormPolicy.editableFillLevel(1.5) == 1)
        precondition(InventoryFormPolicy.editableFillLevel(0.65) == 0.65)
        precondition(InventoryFormPolicy.mergeDraft(live: 8, initial: 2, draft: 2) == 8)
        precondition(InventoryFormPolicy.mergeDraft(live: 8, initial: 2, draft: 3) == 3)
        precondition(InventoryFormPolicy.mergeDraft(live: "Freezer", initial: "Fridge", draft: "Fridge") == "Freezer")
        precondition(InventoryFormPolicy.mergeDraft(live: Optional("new"), initial: nil, draft: nil) == "new")
        print("PASS: 19 Inventory form policy checks (native pure logic; not device UI verification)")
    }
}
