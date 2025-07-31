# Civilizazione - Python Hex Strategy Game

A Python-based hexagonal strategy game similar to Civilization, converted and improved from the original JavaScript React implementation.

## 🚀 Major Improvements

### **From JavaScript to Python**
- **Complete rewrite**: Converted from JavaScript React to Python with pygame
- **Better performance**: Native Python execution vs browser JavaScript
- **Enhanced graphics**: Improved rendering with pygame's optimized graphics
- **Modular architecture**: Clean object-oriented design with dataclasses

### **Visual Enhancements**
- **Better terrain rendering**: More detailed hexagonal tiles with terrain-specific graphics
- **Improved UI**: Cleaner interface with better information display
- **Enhanced unit/city visualization**: Clear icons and status indicators
- **Optimized rendering**: Only draws visible tiles for better performance
- **Camera system**: Smooth camera movement with WASD/arrow keys

### **Game Mechanics Improvements**
- **Proper data structures**: Using Python dataclasses and enums for better code organization
- **Enhanced map generation**: Improved Perlin noise-based terrain generation
- **Better AI framework**: Structured AI system ready for expansion
- **Turn management**: Proper turn-based gameplay with action tracking
- **Visibility system**: Fog of war implementation

## 🎮 How to Play

### Installation
```bash
pip install -r requirements.txt
```

### Running the Game
```bash
python3 civilizazione.py
```

### Controls
- **Mouse**: Click to select units/cities or move selected units
- **SPACE**: End turn
- **T**: Toggle technology tree
- **C**: Toggle city panel (when city selected)
- **WASD/Arrow Keys**: Move camera
- **ESC**: Quit game

### Gameplay Features
- **4 Civilizations**: Human Empire, Alexander's Macedonia, Gandhi's India, Elizabeth's England
- **Unit Types**: Warriors, Scouts, Settlers, Workers, Archers, Spearmen, Horsemen, Swordsmen
- **Terrain Types**: Ocean, Water, Plains, Grassland, Forest, Hills, Mountains
- **Resources**: Gold, Iron, Lumber, Horses, Wheat, Fish
- **Technology Tree**: Research new technologies to unlock units and buildings
- **City Management**: Build cities, manage population and production

## 🛠️ Technical Architecture

### Core Components
- **HexGame**: Main game class handling pygame loop and rendering
- **GameState**: Central game state management
- **Civilization**: Player/AI civilization data
- **City**: City management and production
- **Unit**: Unit movement and combat
- **HexTile**: Hexagonal map tiles with terrain and resources

### Key Improvements Over JavaScript Version
1. **Type Safety**: Full type hints using Python typing system
2. **Data Classes**: Structured data using @dataclass decorator
3. **Enums**: Proper enumeration for game constants
4. **Modular Design**: Clear separation of concerns
5. **Performance**: Optimized rendering with viewport culling

## 🎯 Game Features

### Map Generation
- **Perlin Noise**: Realistic terrain generation
- **Natural Rivers**: Procedurally generated river systems
- **Strategic Resources**: Balanced resource placement
- **Varied Terrain**: 7 different terrain types with unique properties

### Civilization Management
- **Multiple Resources**: Gold, Science, Culture, Faith, Food, Production
- **Technology Research**: Unlock new units and buildings
- **City Growth**: Population-based city expansion
- **Unit Production**: Build and manage military and civilian units

### AI System
- **Multiple AI Personalities**: Alexander (aggressive), Gandhi (peaceful), Elizabeth (balanced)
- **Turn-based AI**: Structured AI decision making
- **Expandable Framework**: Easy to add new AI behaviors

## 🔧 Testing

Run the test suite to verify the conversion:
```bash
python3 test_game.py
```

This will verify:
- All imports work correctly
- Game objects initialize properly
- Map generation functions
- Civilizations and units are created
- Core game mechanics work

## 🎨 Screenshots

The game features:
- **Hexagonal Grid**: Proper hex-based strategy gameplay
- **Detailed Terrain**: Visual representation of different terrain types
- **Clear UI**: Information panels showing resources and game state
- **Unit Icons**: Easy-to-identify unit types
- **City Visualization**: Clear city representation with population indicators

## 🚧 Future Enhancements

The Python architecture makes it easy to add:
- **Combat System**: Detailed unit combat mechanics
- **Diplomacy**: Trade and diplomatic relations between civilizations
- **Victory Conditions**: Multiple ways to win the game
- **More Units/Buildings**: Expanded unit and building trees
- **Multiplayer**: Network-based multiplayer support
- **Save/Load**: Game state persistence
- **Modding Support**: Plugin system for custom content

## 📝 Conversion Notes

The original JavaScript file (`Examples.js`) contained:
- React-based UI components
- HTML5 Canvas rendering
- Complex state management with hooks
- Incomplete implementation (missing closing braces)

The Python version provides:
- Complete, working implementation
- Better performance and stability
- Enhanced graphics and UI
- Expandable architecture
- Full game loop and mechanics

This represents a significant upgrade from the original JavaScript prototype to a fully functional Python game.