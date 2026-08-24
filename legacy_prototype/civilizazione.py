#!/usr/bin/env python3
"""
Civilizazione - A Python-based hexagonal strategy game
Converted and improved from JavaScript React implementation
"""

import pygame
import math
import random
import json
from typing import Dict, List, Optional, Tuple, Set
from dataclasses import dataclass, field
from enum import Enum
from collections import defaultdict

# Initialize Pygame
pygame.init()

# Game Constants
WINDOW_WIDTH = 1200
WINDOW_HEIGHT = 800
HEX_SIZE = 35
MAP_WIDTH = 20
MAP_HEIGHT = 15
FPS = 60

# Colors
COLORS = {
    'ocean': (30, 64, 175),
    'water': (14, 165, 233),
    'plains': (234, 179, 8),
    'grassland': (22, 163, 74),
    'forest': (22, 101, 52),
    'hills': (163, 163, 163),
    'mountains': (82, 82, 82),
    'black': (0, 0, 0),
    'white': (255, 255, 255),
    'gray': (128, 128, 128),
    'light_gray': (200, 200, 200),
    'dark_gray': (50, 50, 50),
    'red': (220, 38, 38),
    'blue': (37, 99, 235),
    'green': (5, 150, 105),
    'purple': (124, 58, 237),
    'yellow': (251, 191, 36),
    'orange': (249, 115, 22),
}

class TerrainType(Enum):
    OCEAN = "ocean"
    WATER = "water"
    PLAINS = "plains"
    GRASSLAND = "grassland"
    FOREST = "forest"
    HILLS = "hills"
    MOUNTAINS = "mountains"

class ResourceType(Enum):
    GOLD = "gold"
    IRON = "iron"
    LUMBER = "lumber"
    HORSES = "horses"
    WHEAT = "wheat"
    FISH = "fish"

class UnitType(Enum):
    WARRIOR = "warrior"
    SCOUT = "scout"
    SETTLER = "settler"
    WORKER = "worker"
    ARCHER = "archer"
    SPEARMAN = "spearman"
    HORSEMAN = "horseman"
    SWORDSMAN = "swordsman"

@dataclass
class Technology:
    name: str
    cost: int
    prerequisites: List[str]
    unlocks: List[str]

@dataclass
class UnitStats:
    name: str
    combat: int
    ranged: int
    cost: int
    movement: int
    unit_type: str

@dataclass
class Building:
    name: str
    cost: int
    food: int = 0
    production: int = 0
    gold: int = 0
    science: int = 0
    culture: int = 0
    defense: int = 0
    experience: int = 0
    unlocked_by: List[str] = field(default_factory=list)

@dataclass
class HexTile:
    q: int
    r: int
    terrain: TerrainType
    resource: Optional[ResourceType] = None
    elevation: float = 0.0
    visible: List[bool] = field(default_factory=lambda: [False] * 4)
    has_river: bool = False
    has_road: bool = False
    improvement: Optional[str] = None
    owner: Optional[int] = None

@dataclass
class Unit:
    id: str
    unit_type: UnitType
    position: Tuple[int, int]
    owner: int
    health: int = 100
    movement: int = 0
    max_movement: int = 0
    has_acted: bool = False
    experience: int = 0
    promotions: List[str] = field(default_factory=list)

@dataclass
class City:
    id: str
    name: str
    position: Tuple[int, int]
    owner: int
    population: int = 1
    food: int = 2
    production: int = 2
    gold: int = 1
    science: int = 1
    culture: int = 1
    current_production: Optional[str] = None
    production_progress: int = 0
    buildings: List[str] = field(default_factory=lambda: ['palace'])
    working_tiles: List[Tuple[int, int]] = field(default_factory=list)
    is_capital: bool = False
    founded: int = 1
    defense_strength: int = 8

@dataclass
class Civilization:
    id: int
    name: str
    color: Tuple[int, int, int]
    is_ai: bool = False
    personality: Optional[str] = None
    gold: int = 100
    science: int = 0
    culture: int = 0
    faith: int = 0
    food: int = 0
    production: int = 0
    units: List[Unit] = field(default_factory=list)
    cities: List[City] = field(default_factory=list)
    technologies: Set[str] = field(default_factory=lambda: {'Agriculture'})
    current_research: Optional[str] = None
    research_progress: int = 0
    policies: List[str] = field(default_factory=list)
    relationships: Dict[int, int] = field(default_factory=dict)
    score: int = 0

class GameState:
    def __init__(self):
        self.turn = 1
        self.current_player = 0
        self.map: List[List[HexTile]] = []
        self.civilizations: List[Civilization] = []
        self.selected_unit: Optional[Unit] = None
        self.selected_city: Optional[City] = None
        self.game_won = False
        self.winner: Optional[int] = None
        self.game_log: List[str] = []

class HexGame:
    def __init__(self):
        self.screen = pygame.display.set_mode((WINDOW_WIDTH, WINDOW_HEIGHT))
        pygame.display.set_caption("Civilizazione - Hex Strategy Game")
        self.clock = pygame.time.Clock()
        self.running = True
        self.font = pygame.font.Font(None, 24)
        self.small_font = pygame.font.Font(None, 16)
        
        # Game data
        self.technologies = self._init_technologies()
        self.unit_types = self._init_unit_types()
        self.buildings = self._init_buildings()
        
        # Game state
        self.game_state = GameState()
        self._init_game()
        
        # UI state
        self.show_tech_tree = False
        self.show_city_panel = False
        self.camera_x = 0
        self.camera_y = 0
        
    def _init_technologies(self) -> Dict[str, Technology]:
        """Initialize the technology tree"""
        return {
            'Agriculture': Technology('Agriculture', 0, [], ['Granary']),
            'Pottery': Technology('Pottery', 35, ['Agriculture'], ['Granary']),
            'Animal Husbandry': Technology('Animal Husbandry', 50, ['Agriculture'], ['Horseman', 'Pasture']),
            'Archery': Technology('Archery', 40, ['Agriculture'], ['Archer']),
            'Bronze Working': Technology('Bronze Working', 65, ['Pottery'], ['Spearman', 'Barracks']),
            'The Wheel': Technology('The Wheel', 55, ['Animal Husbandry'], ['Chariot']),
            'Writing': Technology('Writing', 75, ['Pottery'], ['Library', 'Great Library']),
            'Iron Working': Technology('Iron Working', 120, ['Bronze Working'], ['Swordsman', 'Legion']),
            'Mathematics': Technology('Mathematics', 105, ['The Wheel', 'Writing'], ['Catapult', 'Courthouse']),
            'Construction': Technology('Construction', 85, ['Bronze Working'], ['Colosseum', 'Walls'])
        }
    
    def _init_unit_types(self) -> Dict[str, UnitStats]:
        """Initialize unit type statistics"""
        return {
            'warrior': UnitStats('Warrior', 8, 0, 40, 2, 'melee'),
            'scout': UnitStats('Scout', 5, 0, 25, 3, 'recon'),
            'settler': UnitStats('Settler', 0, 0, 106, 2, 'civilian'),
            'worker': UnitStats('Worker', 0, 0, 70, 2, 'civilian'),
            'archer': UnitStats('Archer', 4, 7, 40, 2, 'ranged'),
            'spearman': UnitStats('Spearman', 11, 0, 56, 2, 'melee'),
            'horseman': UnitStats('Horseman', 12, 0, 75, 4, 'mounted'),
            'swordsman': UnitStats('Swordsman', 14, 0, 75, 2, 'melee')
        }
    
    def _init_buildings(self) -> Dict[str, Building]:
        """Initialize building types"""
        return {
            'granary': Building('Granary', 60, food=2, unlocked_by=['Pottery']),
            'barracks': Building('Barracks', 75, experience=15, unlocked_by=['Bronze Working']),
            'library': Building('Library', 75, science=2, unlocked_by=['Writing']),
            'monument': Building('Monument', 40, culture=2, unlocked_by=[]),
            'walls': Building('Walls', 75, defense=50, unlocked_by=['Construction']),
            'market': Building('Market', 100, gold=2, unlocked_by=[])
        }
    
    def _init_game(self):
        """Initialize the game state"""
        self.game_state.map = self._generate_map()
        self.game_state.civilizations = self._create_civilizations()
        self._place_civilizations()
        self.add_to_log("🌍 Civilization begins! You lead the Human Empire into a new age.")
    
    def _generate_map(self) -> List[List[HexTile]]:
        """Generate a realistic map with terrain features"""
        game_map = []
        noise_map = self._generate_perlin_noise(MAP_WIDTH, MAP_HEIGHT)
        
        for q in range(MAP_WIDTH):
            game_map.append([])
            for r in range(MAP_HEIGHT):
                elevation = noise_map[q][r]
                distance_from_edge = min(q, MAP_WIDTH - q - 1, r, MAP_HEIGHT - r - 1)
                is_coastal = distance_from_edge < 3 and random.random() > 0.6
                
                # Determine terrain based on elevation
                if is_coastal and elevation < 0.3:
                    terrain = TerrainType.OCEAN
                elif elevation < 0.2:
                    terrain = TerrainType.WATER
                elif elevation < 0.35:
                    terrain = TerrainType.PLAINS
                elif elevation < 0.5:
                    terrain = TerrainType.GRASSLAND
                elif elevation < 0.65:
                    terrain = TerrainType.FOREST
                elif elevation < 0.8:
                    terrain = TerrainType.HILLS
                else:
                    terrain = TerrainType.MOUNTAINS
                
                # Add resources
                resource = None
                if terrain == TerrainType.HILLS and random.random() > 0.85:
                    resource = ResourceType.IRON
                elif terrain == TerrainType.MOUNTAINS and random.random() > 0.9:
                    resource = ResourceType.GOLD
                elif terrain == TerrainType.FOREST and random.random() > 0.92:
                    resource = ResourceType.LUMBER
                elif terrain == TerrainType.PLAINS and random.random() > 0.93:
                    resource = ResourceType.HORSES
                elif terrain == TerrainType.GRASSLAND and random.random() > 0.95:
                    resource = ResourceType.WHEAT
                elif terrain == TerrainType.OCEAN and random.random() > 0.96:
                    resource = ResourceType.FISH
                
                tile = HexTile(
                    q=q, r=r, terrain=terrain, resource=resource,
                    elevation=elevation,
                    has_river=(random.random() > 0.92 and terrain not in [TerrainType.OCEAN, TerrainType.WATER])
                )
                game_map[q].append(tile)
        
        # Add rivers
        for _ in range(5):
            self._create_river(game_map)
        
        return game_map
    
    def _generate_perlin_noise(self, width: int, height: int) -> List[List[float]]:
        """Generate Perlin-like noise for terrain generation"""
        noise = []
        for x in range(width):
            noise.append([])
            for y in range(height):
                value = 0
                amplitude = 1
                frequency = 0.1
                
                for _ in range(4):
                    value += amplitude * math.sin(frequency * x) * math.cos(frequency * y)
                    amplitude *= 0.5
                    frequency *= 2
                
                noise[x].append((value + 1) / 2)
        
        return noise
    
    def _create_river(self, game_map: List[List[HexTile]]):
        """Create a river on the map"""
        q = random.randint(0, MAP_WIDTH - 1)
        r = random.randint(0, MAP_HEIGHT - 1)
        length = 5 + random.randint(0, 7)
        
        directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        
        for _ in range(length):
            if 0 <= q < MAP_WIDTH and 0 <= r < MAP_HEIGHT:
                tile = game_map[q][r]
                if tile.terrain not in [TerrainType.OCEAN, TerrainType.WATER]:
                    tile.has_river = True
            
            dq, dr = random.choice(directions)
            q += dq
            r += dr
    
    def _create_civilizations(self) -> List[Civilization]:
        """Create the civilizations"""
        return [
            Civilization(
                id=0, name="Human Empire", color=COLORS['blue'], is_ai=False
            ),
            Civilization(
                id=1, name="Alexander's Macedonia", color=COLORS['red'], is_ai=True, personality="Alexander"
            ),
            Civilization(
                id=2, name="Gandhi's India", color=COLORS['green'], is_ai=True, personality="Gandhi"
            ),
            Civilization(
                id=3, name="Elizabeth's England", color=COLORS['purple'], is_ai=True, personality="Elizabeth"
            )
        ]
    
    def _place_civilizations(self):
        """Place civilizations on the map"""
        # Find good starting positions
        good_positions = []
        for q in range(2, MAP_WIDTH - 2):
            for r in range(2, MAP_HEIGHT - 2):
                tile = self.game_state.map[q][r]
                if tile.terrain in [TerrainType.GRASSLAND, TerrainType.PLAINS]:
                    good_positions.append((q, r))
        
        # Place civilizations spread apart
        start_positions = []
        for i in range(4):
            if not good_positions:
                break
                
            best_pos = good_positions[0]
            max_distance = 0
            
            for pos in good_positions:
                min_dist_to_others = float('inf')
                for other_pos in start_positions:
                    dist = abs(pos[0] - other_pos[0]) + abs(pos[1] - other_pos[1])
                    min_dist_to_others = min(min_dist_to_others, dist)
                
                if min_dist_to_others > max_distance:
                    max_distance = min_dist_to_others
                    best_pos = pos
            
            start_positions.append(best_pos)
        
        # Create cities and starting units for each civilization
        for i, civ in enumerate(self.game_state.civilizations):
            if i >= len(start_positions):
                break
                
            pos = start_positions[i]
            
            # Create capital city
            city = City(
                id=f"city_{civ.id}_0",
                name="Capital" if civ.id == 0 else f"{civ.name.split()[0]} Capital",
                position=pos,
                owner=civ.id,
                is_capital=True
            )
            civ.cities.append(city)
            
            # Set tile ownership around capital
            for dq in range(-1, 2):
                for dr in range(-1, 2):
                    new_q, new_r = pos[0] + dq, pos[1] + dr
                    if 0 <= new_q < MAP_WIDTH and 0 <= new_r < MAP_HEIGHT:
                        self.game_state.map[new_q][new_r].owner = civ.id
            
            # Create starting units
            unit_positions = [
                (pos[0] + 1, pos[1]),
                (pos[0], pos[1] + 1),
                (pos[0] - 1, pos[1])
            ]
            
            units_to_create = [
                (UnitType.WARRIOR, 2),
                (UnitType.SCOUT, 3),
                (UnitType.SETTLER, 2)
            ]
            
            for j, (unit_type, movement) in enumerate(units_to_create):
                if j < len(unit_positions):
                    unit = Unit(
                        id=f"unit_{civ.id}_{j}",
                        unit_type=unit_type,
                        position=unit_positions[j],
                        owner=civ.id,
                        movement=movement,
                        max_movement=movement
                    )
                    civ.units.append(unit)
            
            # Set visibility around starting position
            for dq in range(-3, 4):
                for dr in range(-3, 4):
                    new_q, new_r = pos[0] + dq, pos[1] + dr
                    if 0 <= new_q < MAP_WIDTH and 0 <= new_r < MAP_HEIGHT:
                        self.game_state.map[new_q][new_r].visible[civ.id] = True
    
    def hex_to_pixel(self, q: int, r: int) -> Tuple[int, int]:
        """Convert hex coordinates to pixel coordinates"""
        x = HEX_SIZE * (3/2 * q) + 120 + self.camera_x
        y = HEX_SIZE * (math.sqrt(3)/2 * q + math.sqrt(3) * r) + 60 + self.camera_y
        return int(x), int(y)
    
    def pixel_to_hex(self, x: int, y: int) -> Tuple[int, int]:
        """Convert pixel coordinates to hex coordinates"""
        x -= (120 + self.camera_x)
        y -= (60 + self.camera_y)
        
        q = (2/3 * x) / HEX_SIZE
        r = (-1/3 * x + math.sqrt(3)/3 * y) / HEX_SIZE
        
        return self.hex_round(q, r)
    
    def hex_round(self, q: float, r: float) -> Tuple[int, int]:
        """Round fractional hex coordinates to integer coordinates"""
        s = -q - r
        rq = round(q)
        rr = round(r)
        rs = round(s)
        
        q_diff = abs(rq - q)
        r_diff = abs(rr - r)
        s_diff = abs(rs - s)
        
        if q_diff > r_diff and q_diff > s_diff:
            rq = -rr - rs
        elif r_diff > s_diff:
            rr = -rq - rs
        
        return rq, rr
    
    def add_to_log(self, message: str):
        """Add a message to the game log"""
        self.game_state.game_log.append(message)
        if len(self.game_state.game_log) > 50:  # Keep only recent messages
            self.game_state.game_log.pop(0)
    
    def handle_events(self):
        """Handle pygame events"""
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                self.running = False
            elif event.type == pygame.KEYDOWN:
                if event.key == pygame.K_ESCAPE:
                    self.running = False
                elif event.key == pygame.K_t:
                    self.show_tech_tree = not self.show_tech_tree
                elif event.key == pygame.K_c:
                    self.show_city_panel = not self.show_city_panel
                elif event.key == pygame.K_SPACE:
                    self.end_turn()
            elif event.type == pygame.MOUSEBUTTONDOWN:
                if event.button == 1:  # Left click
                    self.handle_click(event.pos)
            elif event.type == pygame.KEYDOWN:
                # Camera movement
                if event.key == pygame.K_LEFT or event.key == pygame.K_a:
                    self.camera_x += 50
                elif event.key == pygame.K_RIGHT or event.key == pygame.K_d:
                    self.camera_x -= 50
                elif event.key == pygame.K_UP or event.key == pygame.K_w:
                    self.camera_y += 50
                elif event.key == pygame.K_DOWN or event.key == pygame.K_s:
                    self.camera_y -= 50
    
    def handle_click(self, pos: Tuple[int, int]):
        """Handle mouse clicks"""
        hex_pos = self.pixel_to_hex(pos[0], pos[1])
        q, r = hex_pos
        
        if not (0 <= q < MAP_WIDTH and 0 <= r < MAP_HEIGHT):
            return
        
        # Check if clicking on a unit
        clicked_unit = None
        current_civ = self.game_state.civilizations[self.game_state.current_player]
        
        for unit in current_civ.units:
            if unit.position == hex_pos:
                clicked_unit = unit
                break
        
        if clicked_unit:
            self.game_state.selected_unit = clicked_unit
            self.game_state.selected_city = None
        else:
            # Check if clicking on a city
            clicked_city = None
            for city in current_civ.cities:
                if city.position == hex_pos:
                    clicked_city = city
                    break
            
            if clicked_city:
                self.game_state.selected_city = clicked_city
                self.game_state.selected_unit = None
            else:
                # Try to move selected unit
                if self.game_state.selected_unit and not self.game_state.selected_unit.has_acted:
                    self.move_unit(self.game_state.selected_unit, hex_pos)
    
    def move_unit(self, unit: Unit, target_pos: Tuple[int, int]):
        """Move a unit to a target position"""
        if self.can_move_to(unit, target_pos):
            unit.position = target_pos
            unit.movement -= 1
            if unit.movement <= 0:
                unit.has_acted = True
            
            # Update visibility
            self.update_visibility_around_position(target_pos, unit.owner)
            
            self.add_to_log(f"{unit.unit_type.value.title()} moved to ({target_pos[0]}, {target_pos[1]})")
    
    def can_move_to(self, unit: Unit, target_pos: Tuple[int, int]) -> bool:
        """Check if a unit can move to a target position"""
        q, r = target_pos
        
        if not (0 <= q < MAP_WIDTH and 0 <= r < MAP_HEIGHT):
            return False
        
        if unit.movement <= 0:
            return False
        
        # Check if position is occupied by another unit
        for civ in self.game_state.civilizations:
            for other_unit in civ.units:
                if other_unit.position == target_pos and other_unit != unit:
                    return False
        
        # Check terrain (simplified - all terrain passable for now)
        terrain = self.game_state.map[q][r].terrain
        if terrain == TerrainType.OCEAN:
            return False  # Most units can't move on ocean
        
        return True
    
    def update_visibility_around_position(self, pos: Tuple[int, int], player_id: int):
        """Update visibility around a position"""
        q, r = pos
        for dq in range(-2, 3):
            for dr in range(-2, 3):
                new_q, new_r = q + dq, r + dr
                if 0 <= new_q < MAP_WIDTH and 0 <= new_r < MAP_HEIGHT:
                    self.game_state.map[new_q][new_r].visible[player_id] = True
    
    def end_turn(self):
        """End the current player's turn"""
        current_civ = self.game_state.civilizations[self.game_state.current_player]
        
        # Reset unit actions
        for unit in current_civ.units:
            unit.has_acted = False
            unit.movement = unit.max_movement
        
        # Process city production and growth
        for city in current_civ.cities:
            self.process_city_turn(city)
        
        # Advance to next player
        self.game_state.current_player = (self.game_state.current_player + 1) % len(self.game_state.civilizations)
        
        if self.game_state.current_player == 0:
            self.game_state.turn += 1
            self.add_to_log(f"🌅 Turn {self.game_state.turn} begins!")
        
        # Process AI turns
        if self.game_state.civilizations[self.game_state.current_player].is_ai:
            self.process_ai_turn()
    
    def process_city_turn(self, city: City):
        """Process a city's turn"""
        # Simple city growth and production
        city.food += 2
        if city.food >= city.population * 2 + 10:
            city.population += 1
            city.food = 0
            self.add_to_log(f"🏛️ {city.name} grows to population {city.population}!")
        
        # Production
        if city.current_production:
            city.production_progress += city.production
            required_production = self.get_production_cost(city.current_production)
            if city.production_progress >= required_production:
                self.complete_production(city)
    
    def get_production_cost(self, item: str) -> int:
        """Get the production cost of an item"""
        if item in self.unit_types:
            return self.unit_types[item].cost
        elif item in self.buildings:
            return self.buildings[item].cost
        return 100  # Default cost
    
    def complete_production(self, city: City):
        """Complete production in a city"""
        item = city.current_production
        if item in self.unit_types:
            # Create new unit
            new_unit = Unit(
                id=f"unit_{city.owner}_{len(self.game_state.civilizations[city.owner].units)}",
                unit_type=UnitType(item),
                position=city.position,
                owner=city.owner,
                movement=self.unit_types[item].movement,
                max_movement=self.unit_types[item].movement
            )
            self.game_state.civilizations[city.owner].units.append(new_unit)
            self.add_to_log(f"🏭 {city.name} completed {item}!")
        
        city.current_production = None
        city.production_progress = 0
    
    def process_ai_turn(self):
        """Process AI turn (simplified)"""
        current_civ = self.game_state.civilizations[self.game_state.current_player]
        
        # Move units randomly (simplified AI)
        for unit in current_civ.units:
            if not unit.has_acted and unit.movement > 0:
                # Try to move to a random adjacent position
                directions = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)]
                random.shuffle(directions)
                
                for dq, dr in directions:
                    new_pos = (unit.position[0] + dq, unit.position[1] + dr)
                    if self.can_move_to(unit, new_pos):
                        self.move_unit(unit, new_pos)
                        break
        
        # Auto-end AI turn after a short delay
        pygame.time.wait(500)
        self.end_turn()
    
    def update(self):
        """Update game state"""
        pass  # Most updates are event-driven
    
    def draw(self):
        """Draw the game"""
        self.screen.fill(COLORS['dark_gray'])
        
        # Draw map
        self.draw_map()
        
        # Draw UI
        self.draw_ui()
        
        # Draw overlays
        if self.show_tech_tree:
            self.draw_tech_tree()
        if self.show_city_panel and self.game_state.selected_city:
            self.draw_city_panel()
        
        pygame.display.flip()
    
    def draw_hex(self, surface: pygame.Surface, center: Tuple[int, int], size: int, 
                 fill_color: Optional[Tuple[int, int, int]], 
                 stroke_color: Tuple[int, int, int] = COLORS['black'], 
                 stroke_width: int = 1):
        """Draw a hexagon"""
        points = []
        for i in range(6):
            angle = 2 * math.pi / 6 * i
            x = center[0] + size * math.cos(angle)
            y = center[1] + size * math.sin(angle)
            points.append((x, y))
        
        if fill_color:
            pygame.draw.polygon(surface, fill_color, points)
        
        if stroke_width > 0:
            pygame.draw.polygon(surface, stroke_color, points, stroke_width)
    
    def draw_terrain(self, surface: pygame.Surface, center: Tuple[int, int], tile: HexTile):
        """Draw terrain for a hex tile"""
        # Base terrain color
        terrain_colors = {
            TerrainType.OCEAN: COLORS['ocean'],
            TerrainType.WATER: COLORS['water'],
            TerrainType.PLAINS: COLORS['plains'],
            TerrainType.GRASSLAND: COLORS['grassland'],
            TerrainType.FOREST: COLORS['forest'],
            TerrainType.HILLS: COLORS['hills'],
            TerrainType.MOUNTAINS: COLORS['mountains']
        }
        
        base_color = terrain_colors.get(tile.terrain, COLORS['grassland'])
        
        # Draw base hex
        self.draw_hex(surface, center, HEX_SIZE, base_color, COLORS['black'], 1)
        
        # Draw ownership border
        if tile.owner is not None:
            owner_color = self.game_state.civilizations[tile.owner].color
            self.draw_hex(surface, center, HEX_SIZE, None, owner_color, 2)
        
        # Draw terrain features
        if tile.terrain == TerrainType.FOREST:
            # Draw trees
            for i in range(3):
                angle = (i * 2 * math.pi) / 3
                tree_x = center[0] + math.cos(angle) * (HEX_SIZE * 0.3)
                tree_y = center[1] + math.sin(angle) * (HEX_SIZE * 0.3)
                pygame.draw.circle(surface, (21, 128, 61), (int(tree_x), int(tree_y)), 4)
        
        elif tile.terrain == TerrainType.HILLS:
            # Draw hills
            pygame.draw.circle(surface, (212, 212, 216), (center[0] - 8, center[1] - 5), 6)
            pygame.draw.circle(surface, (212, 212, 216), (center[0] + 8, center[1] + 5), 8)
        
        elif tile.terrain == TerrainType.MOUNTAINS:
            # Draw mountains
            points1 = [(center[0] - 10, center[1] + 8), (center[0] - 5, center[1] - 8), (center[0], center[1] + 8)]
            points2 = [(center[0], center[1] + 8), (center[0] + 5, center[1] - 8), (center[0] + 10, center[1] + 8)]
            pygame.draw.polygon(surface, (115, 115, 115), points1)
            pygame.draw.polygon(surface, (115, 115, 115), points2)
        
        # Draw rivers
        if tile.has_river:
            pygame.draw.arc(surface, (59, 130, 246), 
                          (center[0] - HEX_SIZE, center[1] - 10, HEX_SIZE * 2, 20), 
                          0, math.pi, 3)
        
        # Draw resources
        if tile.resource:
            resource_colors = {
                ResourceType.GOLD: COLORS['yellow'],
                ResourceType.IRON: COLORS['gray'],
                ResourceType.LUMBER: (146, 64, 14),
                ResourceType.HORSES: COLORS['orange'],
                ResourceType.WHEAT: (250, 204, 21),
                ResourceType.FISH: (6, 182, 212)
            }
            
            resource_color = resource_colors.get(tile.resource, COLORS['yellow'])
            pygame.draw.circle(surface, resource_color, (center[0] + 12, center[1] - 12), 6)
            
            # Resource icons (simplified)
            resource_icons = {
                ResourceType.GOLD: '◆',
                ResourceType.IRON: '▲',
                ResourceType.LUMBER: '♠',
                ResourceType.HORSES: '♘',
                ResourceType.WHEAT: '※',
                ResourceType.FISH: '≈'
            }
            
            icon = resource_icons.get(tile.resource, '?')
            text = self.small_font.render(icon, True, COLORS['black'])
            text_rect = text.get_rect(center=(center[0] + 12, center[1] - 12))
            surface.blit(text, text_rect)
    
    def draw_map(self):
        """Draw the game map"""
        current_civ = self.game_state.civilizations[self.game_state.current_player]
        
        # Draw tiles
        for q in range(MAP_WIDTH):
            for r in range(MAP_HEIGHT):
                tile = self.game_state.map[q][r]
                center = self.hex_to_pixel(q, r)
                
                # Skip tiles outside screen bounds (optimization)
                if (center[0] < -HEX_SIZE or center[0] > WINDOW_WIDTH + HEX_SIZE or
                    center[1] < -HEX_SIZE or center[1] > WINDOW_HEIGHT + HEX_SIZE):
                    continue
                
                # Only draw visible tiles for human player
                if self.game_state.current_player == 0 and not tile.visible[0]:
                    self.draw_hex(self.screen, center, HEX_SIZE, (31, 41, 55), (55, 65, 81), 1)
                    continue
                
                self.draw_terrain(self.screen, center, tile)
        
        # Draw cities
        for civ in self.game_state.civilizations:
            for city in civ.cities:
                if (self.game_state.current_player == 0 and 
                    not self.game_state.map[city.position[0]][city.position[1]].visible[0]):
                    continue
                
                center = self.hex_to_pixel(city.position[0], city.position[1])
                
                # Skip cities outside screen bounds
                if (center[0] < -HEX_SIZE or center[0] > WINDOW_WIDTH + HEX_SIZE or
                    center[1] < -HEX_SIZE or center[1] > WINDOW_HEIGHT + HEX_SIZE):
                    continue
                
                # City walls
                pygame.draw.rect(self.screen, COLORS['gray'], 
                               (center[0] - 12, center[1] - 12, 24, 24))
                
                # City center
                pygame.draw.rect(self.screen, civ.color, 
                               (center[0] - 8, center[1] - 8, 16, 16))
                
                # City details
                for i in range(2):
                    for j in range(2):
                        pygame.draw.rect(self.screen, COLORS['light_gray'],
                                       (center[0] - 6 + i * 9, center[1] - 6 + j * 9, 3, 3))
                
                # Population indicators
                for i in range(min(city.population, 5)):  # Max 5 dots
                    pygame.draw.circle(self.screen, COLORS['yellow'], 
                                     (center[0] - 8 + i * 4, center[1] - 18), 2)
                
                # City name
                name_text = self.small_font.render(city.name, True, COLORS['black'])
                name_rect = name_text.get_rect(center=(center[0], center[1] - 25))
                self.screen.blit(name_text, name_rect)
                
                # Production indicator
                if city.current_production:
                    prod_text = self.small_font.render(f"🔨{city.current_production}", True, COLORS['purple'])
                    prod_rect = prod_text.get_rect(center=(center[0], center[1] + 25))
                    self.screen.blit(prod_text, prod_rect)
        
        # Draw units
        for civ in self.game_state.civilizations:
            for unit in civ.units:
                if (self.game_state.current_player == 0 and 
                    not self.game_state.map[unit.position[0]][unit.position[1]].visible[0]):
                    continue
                
                center = self.hex_to_pixel(unit.position[0], unit.position[1])
                
                # Skip units outside screen bounds
                if (center[0] < -HEX_SIZE or center[0] > WINDOW_WIDTH + HEX_SIZE or
                    center[1] < -HEX_SIZE or center[1] > WINDOW_HEIGHT + HEX_SIZE):
                    continue
                
                # Unit circle
                pygame.draw.circle(self.screen, civ.color, center, 12)
                pygame.draw.circle(self.screen, COLORS['black'], center, 12, 2)
                
                # Unit type indicator (simplified)
                unit_icons = {
                    UnitType.WARRIOR: 'W',
                    UnitType.SCOUT: 'S',
                    UnitType.SETTLER: 'T',
                    UnitType.WORKER: 'K',
                    UnitType.ARCHER: 'A',
                    UnitType.SPEARMAN: 'P',
                    UnitType.HORSEMAN: 'H',
                    UnitType.SWORDSMAN: 'X'
                }
                
                icon = unit_icons.get(unit.unit_type, '?')
                icon_text = self.small_font.render(icon, True, COLORS['white'])
                icon_rect = icon_text.get_rect(center=center)
                self.screen.blit(icon_text, icon_rect)
                
                # Selection indicator
                if unit == self.game_state.selected_unit:
                    pygame.draw.circle(self.screen, COLORS['yellow'], center, 16, 3)
                
                # Movement indicator
                if unit.has_acted:
                    pygame.draw.circle(self.screen, COLORS['red'], (center[0] + 8, center[1] - 8), 3)
    
    def draw_ui(self):
        """Draw the user interface"""
        current_civ = self.game_state.civilizations[self.game_state.current_player]
        
        # Top panel
        panel_rect = pygame.Rect(0, 0, WINDOW_WIDTH, 80)
        pygame.draw.rect(self.screen, COLORS['light_gray'], panel_rect)
        pygame.draw.rect(self.screen, COLORS['black'], panel_rect, 2)
        
        # Civilization info
        civ_text = self.font.render(f"{current_civ.name} - Turn {self.game_state.turn}", True, COLORS['black'])
        self.screen.blit(civ_text, (10, 10))
        
        # Resources
        resource_texts = [
            f"Gold: {current_civ.gold}",
            f"Science: {current_civ.science}",
            f"Culture: {current_civ.culture}",
            f"Units: {len(current_civ.units)}",
            f"Cities: {len(current_civ.cities)}"
        ]
        
        for i, text in enumerate(resource_texts):
            rendered_text = self.small_font.render(text, True, COLORS['black'])
            self.screen.blit(rendered_text, (10 + i * 120, 35))
        
        # Instructions
        instructions = [
            "SPACE: End Turn",
            "T: Tech Tree", 
            "C: City Panel",
            "WASD/Arrows: Move Camera"
        ]
        
        for i, instruction in enumerate(instructions):
            text = self.small_font.render(instruction, True, COLORS['black'])
            self.screen.blit(text, (10 + i * 150, 55))
        
        # Selected unit/city info
        if self.game_state.selected_unit:
            unit = self.game_state.selected_unit
            unit_info = f"Selected: {unit.unit_type.value.title()} (Health: {unit.health}%, Movement: {unit.movement})"
            unit_text = self.small_font.render(unit_info, True, COLORS['black'])
            self.screen.blit(unit_text, (10, WINDOW_HEIGHT - 60))
        
        if self.game_state.selected_city:
            city = self.game_state.selected_city
            city_info = f"Selected: {city.name} (Pop: {city.population}, Production: {city.current_production or 'None'})"
            city_text = self.small_font.render(city_info, True, COLORS['black'])
            self.screen.blit(city_text, (10, WINDOW_HEIGHT - 40))
        
        # Game log
        log_y = WINDOW_HEIGHT - 200
        for i, message in enumerate(self.game_state.game_log[-8:]):  # Show last 8 messages
            log_text = self.small_font.render(message, True, COLORS['white'])
            self.screen.blit(log_text, (WINDOW_WIDTH - 400, log_y + i * 20))
    
    def draw_tech_tree(self):
        """Draw the technology tree overlay"""
        overlay = pygame.Surface((WINDOW_WIDTH, WINDOW_HEIGHT))
        overlay.fill((0, 0, 0))
        overlay.set_alpha(128)
        self.screen.blit(overlay, (0, 0))
        
        # Tech tree panel
        panel_rect = pygame.Rect(100, 100, WINDOW_WIDTH - 200, WINDOW_HEIGHT - 200)
        pygame.draw.rect(self.screen, COLORS['light_gray'], panel_rect)
        pygame.draw.rect(self.screen, COLORS['black'], panel_rect, 3)
        
        title_text = self.font.render("Technology Tree", True, COLORS['black'])
        self.screen.blit(title_text, (120, 120))
        
        current_civ = self.game_state.civilizations[self.game_state.current_player]
        
        # Display technologies
        y = 160
        for tech_name, tech in self.technologies.items():
            if tech_name in current_civ.technologies:
                color = COLORS['green']
                status = "✓"
            else:
                color = COLORS['black']
                status = " "
            
            tech_text = self.small_font.render(f"{status} {tech.name} (Cost: {tech.cost})", True, color)
            self.screen.blit(tech_text, (120, y))
            y += 25
        
        # Instructions
        instruction_text = self.small_font.render("Press T to close", True, COLORS['black'])
        self.screen.blit(instruction_text, (120, WINDOW_HEIGHT - 140))
    
    def draw_city_panel(self):
        """Draw the city management panel"""
        if not self.game_state.selected_city:
            return
        
        city = self.game_state.selected_city
        
        overlay = pygame.Surface((WINDOW_WIDTH, WINDOW_HEIGHT))
        overlay.fill((0, 0, 0))
        overlay.set_alpha(128)
        self.screen.blit(overlay, (0, 0))
        
        # City panel
        panel_rect = pygame.Rect(150, 150, WINDOW_WIDTH - 300, WINDOW_HEIGHT - 300)
        pygame.draw.rect(self.screen, COLORS['light_gray'], panel_rect)
        pygame.draw.rect(self.screen, COLORS['black'], panel_rect, 3)
        
        title_text = self.font.render(f"City of {city.name}", True, COLORS['black'])
        self.screen.blit(title_text, (170, 170))
        
        # City stats
        stats = [
            f"Population: {city.population}",
            f"Food: {city.food}",
            f"Production: {city.production}",
            f"Gold: {city.gold}",
            f"Science: {city.science}",
            f"Culture: {city.culture}"
        ]
        
        y = 210
        for stat in stats:
            stat_text = self.small_font.render(stat, True, COLORS['black'])
            self.screen.blit(stat_text, (170, y))
            y += 25
        
        # Current production
        if city.current_production:
            prod_text = self.small_font.render(f"Producing: {city.current_production}", True, COLORS['purple'])
            self.screen.blit(prod_text, (170, y + 20))
        
        # Instructions
        instruction_text = self.small_font.render("Press C to close", True, COLORS['black'])
        self.screen.blit(instruction_text, (170, WINDOW_HEIGHT - 200))
    
    def run(self):
        """Main game loop"""
        while self.running:
            self.handle_events()
            self.update()
            self.draw()
            self.clock.tick(FPS)
        
        pygame.quit()

if __name__ == "__main__":
    game = HexGame()
    game.run()