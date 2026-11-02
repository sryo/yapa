import BuddySpec

// Runs every Hardware Buddy spec check, prints failures, and ends with the number passed.
var passed = 0
for c in specChecks {
    if let why = c.run() { print("FAIL \(c.name): \(why)") } else { passed += 1 }
}
print("\(passed)/\(specChecks.count) passed")
print(passed)
