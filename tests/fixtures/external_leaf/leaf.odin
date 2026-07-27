package external_leaf

import dependency "../external_dependency"

leaf_name :: proc() {
_ = dependency.dependency_name
}
