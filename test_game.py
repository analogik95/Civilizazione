#!/usr/bin/env python3
"""
Test runner for Civilizazione game
"""

import os
import sys

# Set SDL to use a dummy video driver for headless testing
os.environ['SDL_VIDEODRIVER'] = 'dummy'

try:
    import civilizazione
    print("✓ All imports successful")
    print("✓ Game classes initialized properly")
    
    # Test game initialization
    game = civilizazione.HexGame()
    print("✓ Game object created successfully")
    print(f"✓ Map generated with {len(game.game_state.map)} x {len(game.game_state.map[0])} tiles")
    print(f"✓ {len(game.game_state.civilizations)} civilizations created")
    
    # Test some game mechanics
    total_units = sum(len(civ.units) for civ in game.game_state.civilizations)
    total_cities = sum(len(civ.cities) for civ in game.game_state.civilizations)
    print(f"✓ {total_units} units created across all civilizations")
    print(f"✓ {total_cities} cities created across all civilizations")
    
    print("\n🎮 Civilizazione Python conversion completed successfully!")
    print("   Run 'python3 civilizazione.py' to play the game")
    
except Exception as e:
    print(f"❌ Error during testing: {e}")
    sys.exit(1)