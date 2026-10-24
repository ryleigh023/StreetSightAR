import 'package:camera/camera.dart';

import 'food_service.dart';
import 'scene_classifier.dart';

/// On-device dish identification, using the MobileNetV2 classifier the app
/// already loads for the scene gate.
///
/// The cloud path ([FoodService]) gives much richer answers, but it needs an
/// OpenAI key and a network link, so it is unavailable in exactly the
/// situations where this feature gets shown: no key configured, bad signal,
/// a demo on a locked-down network. ImageNet-1k happens to contain a usable
/// band of food classes, so the model already in memory can name a dish
/// without either.
///
/// Scope is honest about itself: this recognises common dishes and produce,
/// not regional cuisine. Anything it cannot name confidently returns null
/// rather than guessing, because a wrong dish name attached to a confident
/// allergen list is actively dangerous.
class FoodClassifier {
  final SceneClassifier _scene;
  FoodClassifier(this._scene);

  /// ImageNet-1k class indices that are food or drink, with what we can
  /// honestly say about each. Allergens are listed only where the dish
  /// essentially always contains them.
  static const _dishes = <int, FoodResult>{
    925: FoodResult(
      name: 'Guacamole',
      description: 'Mashed avocado dip, usually with lime, onion and coriander.',
      ingredients: ['Avocado', 'Lime', 'Onion', 'Coriander', 'Salt'],
      origin: 'Mexico',
    ),
    926: FoodResult(
      name: 'Consommé',
      description: 'A clear, intensely flavoured broth, clarified until transparent.',
      ingredients: ['Stock', 'Egg white', 'Mirepoix'],
      allergens: ['Egg'],
      origin: 'France',
    ),
    927: FoodResult(
      name: 'Hot pot',
      description: 'Simmering shared broth at the table, with meat and vegetables cooked in it.',
      ingredients: ['Broth', 'Thin-sliced meat', 'Vegetables', 'Noodles'],
      origin: 'China',
    ),
    928: FoodResult(
      name: 'Trifle',
      description: 'Layered sponge, custard, fruit and cream.',
      ingredients: ['Sponge', 'Custard', 'Fruit', 'Cream'],
      allergens: ['Milk', 'Egg', 'Gluten'],
      origin: 'Britain',
    ),
    929: FoodResult(
      name: 'Ice cream',
      description: 'Frozen sweetened dairy.',
      ingredients: ['Milk', 'Cream', 'Sugar'],
      allergens: ['Milk'],
    ),
    930: FoodResult(name: 'Ice lolly', description: 'Frozen flavoured ice on a stick.', ingredients: ['Water', 'Sugar']),
    931: FoodResult(
      name: 'French loaf',
      description: 'Long crusty wheat loaf.',
      ingredients: ['Wheat flour', 'Water', 'Yeast', 'Salt'],
      allergens: ['Gluten'],
      origin: 'France',
    ),
    932: FoodResult(
      name: 'Bagel',
      description: 'Boiled-then-baked ring of dense wheat dough.',
      ingredients: ['Wheat flour', 'Malt', 'Yeast'],
      allergens: ['Gluten'],
    ),
    933: FoodResult(
      name: 'Pretzel',
      description: 'Knotted baked dough with a dark lye crust.',
      ingredients: ['Wheat flour', 'Yeast', 'Salt'],
      allergens: ['Gluten'],
      origin: 'Germany',
    ),
    934: FoodResult(
      name: 'Cheeseburger',
      description: 'Beef patty with melted cheese in a bun.',
      ingredients: ['Beef', 'Cheese', 'Bun'],
      allergens: ['Gluten', 'Milk'],
    ),
    935: FoodResult(
      name: 'Hot dog',
      description: 'Sausage served in a long soft roll.',
      ingredients: ['Sausage', 'Roll'],
      allergens: ['Gluten'],
    ),
    936: FoodResult(
      name: 'Mashed potato',
      description: 'Potato boiled and mashed, usually with butter and milk.',
      ingredients: ['Potato', 'Butter', 'Milk'],
      allergens: ['Milk'],
    ),
    937: FoodResult(name: 'Cabbage', description: 'Leafy brassica, eaten raw or cooked.', ingredients: ['Cabbage']),
    938: FoodResult(name: 'Broccoli', description: 'Green brassica florets.', ingredients: ['Broccoli']),
    939: FoodResult(name: 'Cauliflower', description: 'Pale brassica florets.', ingredients: ['Cauliflower']),
    940: FoodResult(name: 'Courgette', description: 'Summer squash, also called zucchini.', ingredients: ['Courgette']),
    944: FoodResult(name: 'Cucumber', description: 'Crisp, mild salad vegetable.', ingredients: ['Cucumber']),
    945: FoodResult(name: 'Artichoke', description: 'Edible thistle bud.', ingredients: ['Artichoke']),
    946: FoodResult(name: 'Bell pepper', description: 'Sweet capsicum, eaten raw or roasted.', ingredients: ['Pepper']),
    948: FoodResult(name: 'Mushroom', description: 'Edible fungus.', ingredients: ['Mushroom']),
    949: FoodResult(name: 'Apple', description: 'Crisp green dessert apple.', ingredients: ['Apple']),
    950: FoodResult(name: 'Strawberry', description: 'Sweet red soft fruit.', ingredients: ['Strawberry']),
    951: FoodResult(name: 'Orange', description: 'Citrus fruit.', ingredients: ['Orange']),
    952: FoodResult(name: 'Lemon', description: 'Sour yellow citrus.', ingredients: ['Lemon']),
    953: FoodResult(name: 'Fig', description: 'Soft sweet fruit with edible seeds.', ingredients: ['Fig']),
    954: FoodResult(name: 'Pineapple', description: 'Tropical fruit, sweet and acidic.', ingredients: ['Pineapple']),
    955: FoodResult(name: 'Banana', description: 'Soft sweet tropical fruit.', ingredients: ['Banana']),
    956: FoodResult(name: 'Jackfruit', description: 'Very large tropical fruit, often used as a meat substitute.', ingredients: ['Jackfruit']),
    958: FoodResult(name: 'Pomegranate', description: 'Fruit full of juicy seed arils.', ingredients: ['Pomegranate']),
    960: FoodResult(
      name: 'Spaghetti carbonara',
      description: 'Pasta bound in egg, hard cheese and cured pork. No cream, traditionally.',
      ingredients: ['Spaghetti', 'Egg', 'Pecorino', 'Guanciale', 'Black pepper'],
      allergens: ['Gluten', 'Egg', 'Milk'],
      origin: 'Rome, Italy',
    ),
    961: FoodResult(
      name: 'Chocolate sauce',
      description: 'Sweet chocolate pouring sauce.',
      ingredients: ['Cocoa', 'Sugar', 'Milk'],
      allergens: ['Milk'],
    ),
    962: FoodResult(
      name: 'Dough',
      description: 'Uncooked flour dough.',
      ingredients: ['Flour', 'Water'],
      allergens: ['Gluten'],
    ),
    963: FoodResult(
      name: 'Meatloaf',
      description: 'Seasoned minced meat baked as a loaf.',
      ingredients: ['Minced meat', 'Breadcrumb', 'Egg', 'Onion'],
      allergens: ['Gluten', 'Egg'],
    ),
    964: FoodResult(
      name: 'Pizza',
      description: 'Flatbread baked with tomato and cheese.',
      ingredients: ['Wheat flour', 'Tomato', 'Mozzarella', 'Olive oil'],
      allergens: ['Gluten', 'Milk'],
      origin: 'Naples, Italy',
    ),
    965: FoodResult(
      name: 'Pot pie',
      description: 'Savoury filling baked under a pastry lid.',
      ingredients: ['Pastry', 'Meat or vegetables', 'Stock'],
      allergens: ['Gluten', 'Milk'],
    ),
    966: FoodResult(
      name: 'Burrito',
      description: 'Wheat tortilla wrapped around a filling of beans, rice and meat.',
      ingredients: ['Tortilla', 'Beans', 'Rice', 'Meat'],
      allergens: ['Gluten'],
      origin: 'Mexico',
    ),
    967: FoodResult(name: 'Red wine', description: 'Wine from dark grapes.', ingredients: ['Grapes'], allergens: ['Sulphites']),
    968: FoodResult(
      name: 'Espresso',
      description: 'Short, concentrated coffee pulled under pressure.',
      ingredients: ['Coffee'],
      origin: 'Italy',
    ),
    970: FoodResult(
      name: 'Eggnog',
      description: 'Sweet drink of milk, cream and beaten egg.',
      ingredients: ['Milk', 'Cream', 'Egg', 'Sugar'],
      allergens: ['Milk', 'Egg'],
    ),
  };

  /// Below this the model is effectively guessing, and a confidently
  /// presented wrong dish is worse than admitting we do not know.
  static const _minConfidence = 0.18;

  /// Returns the dish in frame, or null if nothing recognisable is there.
  Future<FoodResult?> identify(CameraImage image, int sensorOrientation) async {
    final ranked = await _scene.classify(image, sensorOrientation);
    for (final (index, score) in ranked) {
      final dish = _dishes[index];
      if (dish == null) continue;
      if (score < _minConfidence) return null; // best food guess is too weak
      return dish;
    }
    return null;
  }
}
