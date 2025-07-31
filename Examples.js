import React, { useState, useEffect, useRef } from 'react';

const HexStrategyGame = () => {
  const canvasRef = useRef(null);
  const [gameState, setGameState] = useState(null);
  const [currentPlayer, setCurrentPlayer] = useState(0);
  const [selectedUnit, setSelectedUnit] = useState(null);
  const [selectedCity, setSelectedCity] = useState(null);
  const [gameLog, setGameLog] = useState([]);
  const [isAIThinking, setIsAIThinking] = useState(false);
  const [showTechTree, setShowTechTree] = useState(false);
  const [showCityPanel, setShowCityPanel] = useState(false);

  // Game constants
  const HEX_SIZE = 35;
  const MAP_WIDTH = 20;
  const MAP_HEIGHT = 15;

  // Technology tree
  const TECHNOLOGIES = {
    'Agriculture': { name: 'Agriculture', cost: 0, prerequisites: [], unlocks: ['Granary'] },
    'Pottery': { name: 'Pottery', cost: 35, prerequisites: ['Agriculture'], unlocks: ['Granary'] },
    'Animal Husbandry': { name: 'Animal Husbandry', cost: 50, prerequisites: ['Agriculture'], unlocks: ['Horseman', 'Pasture'] },
    'Archery': { name: 'Archery', cost: 40, prerequisites: ['Agriculture'], unlocks: ['Archer'] },
    'Bronze Working': { name: 'Bronze Working', cost: 65, prerequisites: ['Pottery'], unlocks: ['Spearman', 'Barracks'] },
    'The Wheel': { name: 'The Wheel', cost: 55, prerequisites: ['Animal Husbandry'], unlocks: ['Chariot'] },
    'Writing': { name: 'Writing', cost: 75, prerequisites: ['Pottery'], unlocks: ['Library', 'Great Library'] },
    'Iron Working': { name: 'Iron Working', cost: 120, prerequisites: ['Bronze Working'], unlocks: ['Swordsman', 'Legion'] },
    'Mathematics': { name: 'Mathematics', cost: 105, prerequisites: ['The Wheel', 'Writing'], unlocks: ['Catapult', 'Courthouse'] },
    'Construction': { name: 'Construction', cost: 85, prerequisites: ['Bronze Working'], unlocks: ['Colosseum', 'Walls'] }
  };

  // Unit types with combat stats
  const UNIT_TYPES = {
    'warrior': { name: 'Warrior', combat: 8, ranged: 0, cost: 40, movement: 2, type: 'melee' },
    'scout': { name: 'Scout', combat: 5, ranged: 0, cost: 25, movement: 3, type: 'recon' },
    'settler': { name: 'Settler', combat: 0, ranged: 0, cost: 106, movement: 2, type: 'civilian' },
    'worker': { name: 'Worker', combat: 0, ranged: 0, cost: 70, movement: 2, type: 'civilian' },
    'archer': { name: 'Archer', combat: 4, ranged: 7, cost: 40, movement: 2, type: 'ranged' },
    'spearman': { name: 'Spearman', combat: 11, ranged: 0, cost: 56, movement: 2, type: 'melee' },
    'horseman': { name: 'Horseman', combat: 12, ranged: 0, cost: 75, movement: 4, type: 'mounted' },
    'swordsman': { name: 'Swordsman', combat: 14, ranged: 0, cost: 75, movement: 2, type: 'melee' }
  };

  // Building types
  const BUILDINGS = {
    'granary': { name: 'Granary', cost: 60, food: 2, unlocked: ['Pottery'] },
    'barracks': { name: 'Barracks', cost: 75, experience: 15, unlocked: ['Bronze Working'] },
    'library': { name: 'Library', cost: 75, science: 2, unlocked: ['Writing'] },
    'monument': { name: 'Monument', cost: 40, culture: 2, unlocked: [] },
    'walls': { name: 'Walls', cost: 75, defense: 50, unlocked: ['Construction'] },
    'market': { name: 'Market', cost: 100, gold: 2, unlocked: [] }
  };

  // Initialize game
  useEffect(() => {
    const initialState = createInitialGameState();
    setGameState(initialState);
    addToLog("🌍 Civilization begins! You lead the Human Empire into a new age.");
  }, []);

  // Canvas drawing
  useEffect(() => {
    if (gameState && canvasRef.current) {
      drawGame();
    }
  }, [gameState, selectedUnit, selectedCity]);

  const createInitialGameState = () => {
    // Create realistic terrain with natural features
    const map = [];
    const noiseMap = generatePerlinNoise(MAP_WIDTH, MAP_HEIGHT);
    
    for (let q = 0; q < MAP_WIDTH; q++) {
      map[q] = [];
      for (let r = 0; r < MAP_HEIGHT; r++) {
        const elevation = noiseMap[q][r];
        const distanceFromEdge = Math.min(q, MAP_WIDTH - q - 1, r, MAP_HEIGHT - r - 1);
        const isCoastal = distanceFromEdge < 3 && Math.random() > 0.6;
        
        let terrain, resource = null;
        
        if (isCoastal && elevation < 0.3) {
          terrain = 'ocean';
        } else if (elevation < 0.2) {
          terrain = 'water';
        } else if (elevation < 0.35) {
          terrain = 'plains';
        } else if (elevation < 0.5) {
          terrain = 'grassland';
        } else if (elevation < 0.65) {
          terrain = 'forest';
        } else if (elevation < 0.8) {
          terrain = 'hills';
        } else {
          terrain = 'mountains';
        }
        
        // Add strategic and luxury resources
        if (terrain === 'hills' && Math.random() > 0.85) resource = 'iron';
        else if (terrain === 'mountains' && Math.random() > 0.9) resource = 'gold';
        else if (terrain === 'forest' && Math.random() > 0.92) resource = 'lumber';
        else if (terrain === 'plains' && Math.random() > 0.93) resource = 'horses';
        else if (terrain === 'grassland' && Math.random() > 0.95) resource = 'wheat';
        else if (terrain === 'ocean' && Math.random() > 0.96) resource = 'fish';
        
        map[q][r] = {
          terrain: terrain,
          resource: resource,
          elevation: elevation,
          visible: [false, false, false, false],
          hasRiver: Math.random() > 0.92 && terrain !== 'ocean' && terrain !== 'water',
          hasRoad: false,
          improvement: null,
          owner: null
        };
      }
    }

    // Add rivers that flow naturally
    for (let i = 0; i < 5; i++) {
      createRiver(map);
    }

    // Create civilizations with enhanced stats
    const civilizations = [
      {
        id: 0,
        name: "Human Empire",
        color: "#2563EB",
        isAI: false,
        gold: 100,
        science: 0,
        culture: 0,
        faith: 0,
        food: 0,
        production: 0,
        units: [],
        cities: [],
        technologies: new Set(['Agriculture']),
        currentResearch: null,
        researchProgress: 0,
        policies: [],
        relationships: {},
        score: 0
      },
      {
        id: 1,
        name: "Alexander's Macedonia",
        color: "#DC2626",
        isAI: true,
        personality: "Alexander",
        gold: 100,
        science: 0,
        culture: 0,
        faith: 0,
        food: 0,
        production: 0,
        units: [],
        cities: [],
        technologies: new Set(['Agriculture']),
        currentResearch: 'Bronze Working',
        researchProgress: 0,
        policies: [],
        relationships: {},
        score: 0
      },
      {
        id: 2,
        name: "Gandhi's India",
        color: "#059669",
        isAI: true,
        personality: "Gandhi",
        gold: 100,
        science: 0,
        culture: 0,
        faith: 0,
        food: 0,
        production: 0,
        units: [],
        cities: [],
        technologies: new Set(['Agriculture']),
        currentResearch: 'Pottery',
        researchProgress: 0,
        policies: [],
        relationships: {},
        score: 0
      },
      {
        id: 3,
        name: "Elizabeth's England",
        color: "#7C3AED",
        isAI: true,
        personality: "Elizabeth",
        gold: 100,
        science: 0,
        culture: 0,
        faith: 0,
        food: 0,
        production: 0,
        units: [],
        cities: [],
        technologies: new Set(['Agriculture']),
        currentResearch: 'Archery',
        researchProgress: 0,
        policies: [],
        relationships: {},
        score: 0
      }
    ];

    // Find good starting positions
    const goodPositions = [];
    for (let q = 2; q < MAP_WIDTH - 2; q++) {
      for (let r = 2; r < MAP_HEIGHT - 2; r++) {
        const tile = map[q][r];
        if (tile.terrain === 'grassland' || tile.terrain === 'plains') {
          goodPositions.push({q, r});
        }
      }
    }

    // Place civilizations at good positions, spread apart
    const startPositions = [];
    for (let i = 0; i < 4; i++) {
      let bestPos = goodPositions[0];
      let maxDistance = 0;
      
      for (const pos of goodPositions) {
        let minDistToOthers = Infinity;
        for (const other of startPositions) {
          const dist = Math.abs(pos.q - other.q) + Math.abs(pos.r - other.r);
          minDistToOthers = Math.min(minDistToOthers, dist);
        }
        if (minDistToOthers > maxDistance) {
          maxDistance = minDistToOthers;
          bestPos = pos;
        }
      }
      startPositions.push(bestPos);
    }

    civilizations.forEach((civ, index) => {
      const pos = startPositions[index];
      
      // Add capital city
      const city = {
        id: `city_${civ.id}_0`,
        name: civ.id === 0 ? "Capital" : `${civ.name.split("'s")[0]} Capital`,
        position: pos,
        owner: civ.id,
        population: 1,
        food: 2,
        production: 2,
        gold: 1,
        science: 1,
        culture: 1,
        currentProduction: null,
        productionProgress: 0,
        buildings: ['palace'],
        workingTiles: [],
        isCapital: true,
        founded: 1,
        defenseStrength: 8
      };
      civ.cities.push(city);

      // Set tile ownership around capital
      for (let dq = -1; dq <= 1; dq++) {
        for (let dr = -1; dr <= 1; dr++) {
          const newQ = pos.q + dq;
          const newR = pos.r + dr;
          if (newQ >= 0 && newQ < MAP_WIDTH && newR >= 0 && newR < MAP_HEIGHT) {
            map[newQ][newR].owner = civ.id;
          }
        }
      }

      // Add starting units
      const unitPositions = [
        {q: pos.q + 1, r: pos.r},
        {q: pos.q, r: pos.r + 1},
        {q: pos.q - 1, r: pos.r}
      ];

      const warrior = {
        id: `unit_${civ.id}_0`,
        type: 'warrior',
        position: unitPositions[0],
        owner: civ.id,
        health: 100,
        movement: 2,
        maxMovement: 2,
        hasActed: false,
        experience: 0,
        promotions: []
      };

      const scout = {
        id: `unit_${civ.id}_1`,
        type: 'scout',
        position: unitPositions[1],
        owner: civ.id,
        health: 100,
        movement: 3,
        maxMovement: 3,
        hasActed: false,
        experience: 0,
        promotions: []
      };

      const settler = {
        id: `unit_${civ.id}_2`,
        type: 'settler',
        position: unitPositions[2],
        owner: civ.id,
        health: 100,
        movement: 2,
        maxMovement: 2,
        hasActed: false,
        experience: 0,
        promotions: []
      };

      civ.units.push(warrior, scout, settler);

      // Set visibility around starting position
      for (let dq = -3; dq <= 3; dq++) {
        for (let dr = -3; dr <= 3; dr++) {
          const newQ = pos.q + dq;
          const newR = pos.r + dr;
          if (newQ >= 0 && newQ < MAP_WIDTH && newR >= 0 && newR < MAP_HEIGHT) {
            map[newQ][newR].visible[civ.id] = true;
          }
        }
      }
    });

    return {
      turn: 1,
      currentPlayer: 0,
      map: map,
      civilizations: civilizations,
      selectedUnit: null,
      gameWon: false,
      winner: null
    };
  };

  const generatePerlinNoise = (width, height) => {
    const noise = [];
    for (let x = 0; x < width; x++) {
      noise[x] = [];
      for (let y = 0; y < height; y++) {
        let value = 0;
        let amplitude = 1;
        let frequency = 0.1;
        
        for (let i = 0; i < 4; i++) {
          value += amplitude * Math.sin(frequency * x) * Math.cos(frequency * y);
          amplitude *= 0.5;
          frequency *= 2;
        }
        
        noise[x][y] = (value + 1) / 2;
      }
    }
    return noise;
  };

  const createRiver = (map) => {
    let q = Math.floor(Math.random() * MAP_WIDTH);
    let r = Math.floor(Math.random() * MAP_HEIGHT);
    const length = 5 + Math.floor(Math.random() * 8);
    
    for (let i = 0; i < length; i++) {
      if (q >= 0 && q < MAP_WIDTH && r >= 0 && r < MAP_HEIGHT) {
        if (map[q][r].terrain !== 'ocean' && map[q][r].terrain !== 'water') {
          map[q][r].hasRiver = true;
        }
      }
      
      const directions = [{q: 1, r: 0}, {q: -1, r: 0}, {q: 0, r: 1}, {q: 0, r: -1}];
      const nextDir = directions[Math.floor(Math.random() * directions.length)];
      q += nextDir.q;
      r += nextDir.r;
    }
  };

  const hexToPixel = (q, r) => {
    const x = HEX_SIZE * (3/2 * q);
    const y = HEX_SIZE * (Math.sqrt(3)/2 * q + Math.sqrt(3) * r);
    return {x: x + 120, y: y + 60};
  };

  const pixelToHex = (x, y) => {
    x -= 120;
    y -= 60;
    const q = (2/3 * x) / HEX_SIZE;
    const r = (-1/3 * x + Math.sqrt(3)/3 * y) / HEX_SIZE;
    return hexRound(q, r);
  };

  const hexRound = (q, r) => {
    const s = -q - r;
    let rq = Math.round(q);
    let rr = Math.round(r);
    let rs = Math.round(s);

    const qDiff = Math.abs(rq - q);
    const rDiff = Math.abs(rr - r);
    const sDiff = Math.abs(rs - s);

    if (qDiff > rDiff && qDiff > sDiff) {
      rq = -rr - rs;
    } else if (rDiff > sDiff) {
      rr = -rq - rs;
    }

    return {q: rq, r: rr};
  };

  const drawHex = (ctx, center, size, fillColor, strokeColor = '#333', strokeWidth = 1) => {
    ctx.beginPath();
    for (let i = 0; i < 6; i++) {
      const angle = 2 * Math.PI / 6 * i;
      const x = center.x + size * Math.cos(angle);
      const y = center.y + size * Math.sin(angle);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.closePath();
    
    if (fillColor) {
      ctx.fillStyle = fillColor;
      ctx.fill();
    }
    
    ctx.strokeStyle = strokeColor;
    ctx.lineWidth = strokeWidth;
    ctx.stroke();
  };

  const drawTerrain = (ctx, center, tile) => {
    const size = HEX_SIZE;
    let baseColor, detailColor;

    switch (tile.terrain) {
      case 'ocean':
        baseColor = '#1e40af';
        detailColor = '#3b82f6';
        break;
      case 'water':
        baseColor = '#0ea5e9';
        detailColor = '#38bdf8';
        break;
      case 'plains':
        baseColor = '#eab308';
        detailColor = '#fbbf24';
        break;
      case 'grassland':
        baseColor = '#16a34a';
        detailColor = '#22c55e';
        break;
      case 'forest':
        baseColor = '#166534';
        detailColor = '#15803d';
        break;
      case 'hills':
        baseColor = '#a3a3a3';
        detailColor = '#d4d4d8';
        break;
      case 'mountains':
        baseColor = '#525252';
        detailColor = '#737373';
        break;
      default:
        baseColor = '#22c55e';
        detailColor = '#16a34a';
    }

    // Draw base terrain
    drawHex(ctx, center, size, baseColor, '#333', 1);

    // Draw ownership borders
    if (tile.owner !== null) {
      const ownerColor = gameState.civilizations[tile.owner].color;
      drawHex(ctx, center, size, null, ownerColor, 2);
    }

    // Add terrain details
    if (tile.terrain === 'forest') {
      for (let i = 0; i < 3; i++) {
        const angle = (i * 2 * Math.PI) / 3;
        const treeX = center.x + Math.cos(angle) * (size * 0.3);
        const treeY = center.y + Math.sin(angle) * (size * 0.3);
        
        ctx.fillStyle = '#15803d';
        ctx.beginPath();
        ctx.arc(treeX, treeY, 4, 0, 2 * Math.PI);
        ctx.fill();
      }
    } else if (tile.terrain === 'hills') {
      ctx.fillStyle = detailColor;
      ctx.beginPath();
      ctx.arc(center.x - 8, center.y - 5, 6, 0, 2 * Math.PI);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(center.x + 8, center.y + 5, 8, 0, 2 * Math.PI);
      ctx.fill();
    } else if (tile.terrain === 'mountains') {
      ctx.fillStyle = detailColor;
      ctx.beginPath();
      ctx.moveTo(center.x - 10, center.y + 8);
      ctx.lineTo(center.x - 5, center.y - 8);
      ctx.lineTo(center.x, center.y + 8);
      ctx.fill();
      ctx.beginPath();
      ctx.moveTo(center.x, center.y + 8);
      ctx.lineTo(center.x + 5, center.y - 8);
      ctx.lineTo(center.x + 10, center.y + 8);
      ctx.fill();
    } else if (tile.terrain === 'ocean' || tile.terrain === 'water') {
      ctx.strokeStyle = detailColor;
      ctx.lineWidth = 2;
      for (let i = 0; i < 3; i++) {
        const y = center.y - 10 + i * 7;
        ctx.beginPath();
        ctx.moveTo(center.x - 15, y);
        ctx.quadraticCurveTo(center.x - 5, y - 3, center.x + 5, y);
        ctx.quadraticCurveTo(center.x + 15, y + 3, center.x + 25, y);
        ctx.stroke();
      }
    }

    // Draw rivers
    if (tile.hasRiver) {
      ctx.strokeStyle = '#3b82f6';
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.moveTo(center.x - size * 0.8, center.y);
      ctx.quadraticCurveTo(center.x, center.y - 10, center.x + size * 0.8, center.y);
      ctx.stroke();
    }

    // Draw resources
    if (tile.resource) {
      const resourceColors = {
        'gold': '#fbbf24',
        'iron': '#6b7280',
        'lumber': '#92400e',
        'horses': '#f97316',
        'wheat': '#facc15',
        'fish': '#06b6d4'
      };
      
      ctx.fillStyle = resourceColors[tile.resource] || '#fbbf24';
      ctx.beginPath();
      ctx.arc(center.x + 12, center.y - 12, 6, 0, 2 * Math.PI);
      ctx.fill();
      
      // Resource icon
      ctx.fillStyle = '#000';
      ctx.font = '8px Arial';
      ctx.textAlign = 'center';
      const resourceIcons = {
        'gold': '◆',
        'iron': '▲',
        'lumber': '♠',
        'horses': '♘',
        'wheat': '※',
        'fish': '≈'
      };
      ctx.fillText(resourceIcons[tile.resource] || '?', center.x + 12, center.y - 8);
    }

    // Draw improvements
    if (tile.improvement) {
      ctx.fillStyle = '#8b5cf6';
      ctx.fillRect(center.x - 15, center.y + 10, 8, 8);
    }
  };

  const drawGame = () => {
    const canvas = canvasRef.current;
    const ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    const currentCiv = gameState.civilizations[currentPlayer];

    // Draw hex tiles
    for (let q = 0; q < MAP_WIDTH; q++) {
      for (let r = 0; r < MAP_HEIGHT; r++) {
        const tile = gameState.map[q][r];
        const center = hexToPixel(q, r);
        
        // Only draw visible tiles for human player
        if (currentPlayer === 0 && !tile.visible[0]) {
          drawHex(ctx, center, HEX_SIZE, '#1f2937', '#374151', 1);
          continue;
        }

        drawTerrain(ctx, center, tile);
      }
    }

    // Draw cities
    gameState.civilizations.forEach(civ => {
      civ.cities.forEach(city => {
        if (currentPlayer === 0 && !gameState.map[city.position.q][city.position.r].visible[0]) return;
        
        const center = hexToPixel(city.position.q, city.position.r);
        
        // City walls
        ctx.fillStyle = '#6b7280';
        ctx.fillRect(center.x - 12, center.y - 12, 24, 24);
        
        // City center
        ctx.fillStyle = civ.color;
        ctx.fillRect(center.x - 8, center.y - 8, 16, 16);
        
        // City details
        ctx.fillStyle = '#f3f4f6';
        ctx.fillRect(center.x - 6, center.y - 6, 3, 3);
        ctx.fillRect(center.x + 3, center.y - 6, 3, 3);
        ctx.fillRect(center.x - 6, center.y + 3, 3, 3);
        ctx.fillRect(center.x + 3, center.y + 3, 3, 3);
        
        // Population indicator
        for (let i = 0; i < city.population; i++) {
          ctx.fillStyle = '#fbbf24';
          ctx.beginPath();
          ctx.arc(center.x - 8 + i * 4, center.y - 18, 2, 0, 2 * Math.PI);
          ctx.fill();
        }
        
        // City name
        ctx.fillStyle = '#000';
        ctx.font = 'bold 10px Arial';
        ctx.textAlign = 'center';
        ctx.fillText(city.name, center.x, center.y - 22);

        // Production indicator
        if (city.currentProduction) {
          ctx.fillStyle = '#8b5cf6';
          ctx.font = '8px Arial';
          ctx.fillText(`🔨${city.currentProduction}`, center.x, center.y + 25);
        }

  
