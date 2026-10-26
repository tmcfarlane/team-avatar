---
name: refactoring
description: This skill should be used when the user asks to "refactor code", "rename function", "extract method", "reduce complexity", "migrate code", "code migration", "modernize code", "split class", "move code", or mentions code restructuring and refactoring operations.
version: 1.0.0
---

# Refactoring

Comprehensive refactoring skill for safe code restructuring, migrations, and modernization.

## Core Capabilities

### Safe Renaming

Rename identifiers across the codebase:

**Rename workflow:**

1. **Find all references**: Search for all usages
2. **Identify scope**: Module-local, package-wide, or public API
3. **Check dependencies**: External code that might break
4. **Perform rename**: Update all occurrences
5. **Verify**: Run tests, check imports

**Search patterns:**

```bash
# Find all references to a function
grep -rn "function_name" --include="*.py"

# Find class usages
grep -rn "ClassName" --include="*.py"

# Find imports
grep -rn "from .* import.*function_name" --include="*.py"
```

**Renaming considerations:**

- Update docstrings mentioning the old name
- Update comments referencing the name
- Update configuration files
- Update tests
- Consider deprecation period for public APIs

### Method Extraction

Extract code into separate functions:

**When to extract:**

- Code block is too long (> 20 lines)
- Code is duplicated elsewhere
- Code has a clear single purpose
- Code can be tested independently

**Extraction process:**

1. Identify the code block to extract
2. Determine inputs (parameters)
3. Determine outputs (return values)
4. Create new function with clear name
5. Replace original code with function call
6. Add tests for new function

**Before:**

```python
def process_order(order):
    # Validate order (candidate for extraction)
    if not order.items:
        raise ValueError("Empty order")
    if order.total < 0:
        raise ValueError("Invalid total")
    for item in order.items:
        if item.quantity <= 0:
            raise ValueError("Invalid quantity")

    # Process payment
    payment_result = gateway.charge(order.total)
    return payment_result
```

**After:**

```python
def validate_order(order: Order) -> None:
    """Validate order has valid items and total."""
    if not order.items:
        raise ValueError("Empty order")
    if order.total < 0:
        raise ValueError("Invalid total")
    for item in order.items:
        if item.quantity <= 0:
            raise ValueError("Invalid quantity")

def process_order(order: Order) -> PaymentResult:
    validate_order(order)
    return gateway.charge(order.total)
```

### Class Splitting

Split large classes into focused components:

**When to split:**

- Class has multiple responsibilities
- Class has > 500 lines
- Groups of methods work on different data
- Testing requires excessive mocking

**Splitting strategies:**

**Extract class:**

```python
# Before: God class
class OrderManager:
    def create_order(self): ...
    def validate_order(self): ...
    def calculate_tax(self): ...
    def calculate_shipping(self): ...
    def send_confirmation_email(self): ...
    def send_shipping_notification(self): ...

# After: Focused classes
class OrderService:
    def create_order(self): ...
    def validate_order(self): ...

class PricingService:
    def calculate_tax(self): ...
    def calculate_shipping(self): ...

class NotificationService:
    def send_confirmation_email(self): ...
    def send_shipping_notification(self): ...
```

### Complexity Reduction

Reduce cyclomatic complexity:

**Replace conditionals with polymorphism:**

```python
# Before: Complex switch
def calculate_price(product_type, base_price):
    if product_type == "physical":
        return base_price + shipping_cost
    elif product_type == "digital":
        return base_price
    elif product_type == "subscription":
        return base_price * 12 * 0.9
    else:
        raise ValueError("Unknown type")

# After: Polymorphism
class Product(ABC):
    @abstractmethod
    def calculate_price(self, base_price): ...

class PhysicalProduct(Product):
    def calculate_price(self, base_price):
        return base_price + self.shipping_cost

class DigitalProduct(Product):
    def calculate_price(self, base_price):
        return base_price

class Subscription(Product):
    def calculate_price(self, base_price):
        return base_price * 12 * 0.9
```

**Extract guard clauses:**

```python
# Before: Nested conditionals
def process(data):
    if data:
        if data.is_valid:
            if data.is_ready:
                return do_processing(data)
    return None

# After: Guard clauses
def process(data):
    if not data:
        return None
    if not data.is_valid:
        return None
    if not data.is_ready:
        return None
    return do_processing(data)
```

### Code Migration

Migrate code between patterns or versions:

**Migration types:**

- Python 2 to 3
- Sync to async
- ORM migrations
- API version upgrades
- Framework migrations

**Migration workflow:**

1. **Assess scope**: What needs to change
2. **Create compatibility layer**: If gradual migration
3. **Migrate in phases**: Start with low-risk areas
4. **Maintain tests**: Ensure behavior preserved
5. **Remove old code**: Clean up after migration

**Example: Sync to Async**

```python
# Before: Synchronous
def fetch_user(user_id: int) -> User:
    response = requests.get(f"/users/{user_id}")
    return User.from_dict(response.json())

# After: Asynchronous
async def fetch_user(user_id: int) -> User:
    async with aiohttp.ClientSession() as session:
        async with session.get(f"/users/{user_id}") as response:
            data = await response.json()
            return User.from_dict(data)
```

## Refactoring Workflow

### Safe Refactoring Process

1. **Ensure test coverage**: Add tests if missing
2. **Run tests**: Verify green baseline
3. **Make small change**: One refactoring at a time
4. **Run tests again**: Verify still green
5. **Commit**: Save progress
6. **Repeat**: Continue with next change

### Pre-Refactoring Checklist

```
[ ] Tests exist for affected code
[ ] All tests pass
[ ] Change is well understood
[ ] Impact scope identified
[ ] Rollback plan exists
```

### Post-Refactoring Verification

```
[ ] All tests still pass
[ ] No new linting errors
[ ] Type checking passes
[ ] Functionality unchanged
[ ] Performance acceptable
```

## Common Refactorings

### Remove Dead Code

```python
# Find and remove:
# - Unused imports
# - Unused variables
# - Unreachable code
# - Commented-out code
# - Deprecated functions

# Tools:
# - vulture (Python)
# - autoflake (Python)
# - eslint (JavaScript)
```

### Simplify Expressions

```python
# Before
if condition == True:
    return True
else:
    return False

# After
return condition
```

### Introduce Explaining Variables

```python
# Before
if user.age >= 18 and user.country in ['US', 'CA'] and user.verified:
    allow_purchase()

# After
is_adult = user.age >= 18
is_supported_country = user.country in ['US', 'CA']
is_verified = user.verified
can_purchase = is_adult and is_supported_country and is_verified

if can_purchase:
    allow_purchase()
```

## Safety Guidelines

### Breaking Changes

When refactoring public APIs:

1. Add deprecation warnings first
2. Maintain backwards compatibility
3. Document migration path
4. Remove after deprecation period

### Database Migrations

When refactoring data models:

1. Create migration scripts
2. Test migrations on copy of data
3. Plan for rollback
4. Consider zero-downtime migrations

### Performance Impact

After refactoring:

1. Run performance benchmarks
2. Compare with baseline
3. Profile if regression found
4. Optimize if necessary

## Integration

Coordinate with other skills:

- **code-quality skill**: Measure improvement
- **test-coverage skill**: Ensure test coverage
- **architecture-review skill**: Validate structural changes
- **git-workflows skill**: Proper commit messages for refactors
