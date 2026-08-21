#!/usr/bin/env python3
"""
Screenshot utility for Civilizazione game
Creates a visual representation of the game state
"""

import pygame
import os
import sys

# Set SDL to use a software renderer for better compatibility
os.environ['SDL_VIDEODRIVER'] = 'software'

import civilizazione

def create_game_screenshot():
    """Create a screenshot showing the improved game visualization"""
    try:
        print("Creating game screenshot...")
        
        # Initialize game
        game = civilizazione.HexGame()
        
        # Run a few game updates to set up the initial state
        game.update()
        
        # Draw the current game state
        game.draw()
        
        # Save screenshot
        screenshot_path = "civilizazione_screenshot.png"
        pygame.image.save(game.screen, screenshot_path)
        
        print(f"✓ Screenshot saved as {screenshot_path}")
        print(f"  Resolution: {civilizazione.WINDOW_WIDTH}x{civilizazione.WINDOW_HEIGHT}")
        print("  Features shown:")
        print("    - Hexagonal map with different terrain types")
        print("    - Cities with population indicators")
        print("    - Units with type indicators")
        print("    - Resource icons on appropriate tiles")
        print("    - UI panels showing game information")
        print("    - Technology and civilization data")
        
        # Clean up
        pygame.quit()
        
        return True
        
    except Exception as e:
        print(f"Error creating screenshot: {e}")
        return False

if __name__ == "__main__":
    if create_game_screenshot():
        print("\n🎮 Visual demonstration of Python conversion completed!")
    else:
        print("\n❌ Screenshot creation failed")
        sys.exit(1)