# RE4 Tank Controls

(Note that anytime I refer to Leon, this applies to other playable characters like Ada as well.)

Play Resident Evil 4 (2023) with the tank controls of the original 2005 game. Push forward and Leon walks the way he's facing, left and right turn him, and back walks him backwards.

There's also an optional classic controller layout, so the buttons work the way they did in the original too.

## Requirements

- Resident Evil 4 (2023) on PC
- [REFramework](https://github.com/praydog/REFramework) for Resident Evil 4

## Installation

1. Install REFramework if you haven't already: put its `dinput8.dll` in the game folder.
2. Copy `re4_tank_controls.lua` into the game's `reframework/autorun` folder. If that folder doesn't exist yet, start the game once with REFramework installed and it will be created.
3. Start the game. Tank controls are on straight away.

To uninstall, delete `re4_tank_controls.lua`. Your settings are saved in `reframework/data/re4_tank_controls.json`, which you can delete as well.

## Controls

These work on keyboard and on controller.

| Input | What it does |
|---|---|
| Forward | Walk the way Leon is facing |
| Left / right | Turn Leon, standing still or on the move |
| Back | Walk backwards |
| Back + run | Quick turn (a fast 180) |
| Run | Run, as normal |

The camera swings in behind Leon while he moves or turns. You can still look around with the mouse or right stick.

Like the original:

- Leon can't walk while aiming.
- Raising your weapon aims where Leon is facing, not where the camera happens to be pointing.
- You can't raise a weapon in the middle of a quick turn.

Press **F6** at any time to switch tank controls on or off.

## Settings

Press **Insert** to open the REFramework menu, then open **RE4 Tank Controls**. Changes are saved automatically.

| Setting | What it does |
|---|---|
| Enabled (F6) | Turns the mod on or off |
| Turn speed | How fast Leon turns |
| Stick deadzone | How far you need to push the stick before Leon reacts |
| Camera snaps back when standing still | Off: the camera only follows Leon while he moves, so you can look around freely when standing still. On: it always returns behind him, like the original |
| Snap back delay | How long the camera stays where you put it before swinging back behind Leon |
| Camera height range | How far up or down the camera can stay tilted. Anything beyond this is brought back toward level after aiming and while turning |
| No walking while aiming | Leon plants his feet while a weapon is raised |
| Aim where Leon is facing | Raising a weapon aims straight ahead of Leon, and the camera height resets afterwards |
| Classic controls | The original's controller layout (see below) |

## Classic controller layout

For controllers only. First set up the game's own controller options:

1. Set the control type to **C-1**.
2. Set the quick turn type to **A (Run)**.

Then tick **Classic controls** in the mod's menu.

Buttons are listed with Xbox names. On a PlayStation controller:

| Xbox | PlayStation |
|---|---|
| A | Cross |
| B | Circle |
| X | Square |
| Y | Triangle |
| LB / RB | L1 / R1 |
| LT / RT | L2 / R2 |

| Button | Nothing raised | Gun raised | Knife raised |
|---|---|---|---|
| **RT** | Raise gun | | |
| **LT** or **LB** | Raise knife, parry | | |
| **X** | Interact | Shoot | Slash |
| **A** | Run | Reload | |
| **RB** | | Reload | |
| **Hold back, then A** | Quick turn | | |
| **B** | Crouch | | |
| **Left stick** | Move / turn | Aim | Aim |

The right stick still aims as well.

On-screen prompts still show the game's own buttons. Prompts for knife attacks (sneak attacks, finishing off downed enemies, knifing out of a grab) use **RT**, as shown.

### Special sections

With classic controls on, these sections use the classic layout too. Everything not listed here uses the game's own controls.

- **The lake boat, Del Lago fight:** hold **RT** to ready the harpoon, **X** to throw, and the **left stick** aims. The game's own LB to ready, RT to throw still works.
- **The lake boat, everywhere else:** **RT** is the throttle. Hold **LB** to ready the harpoon, then **X** or **RT** throws, and the left stick aims.
- **Minecart:** hold **RT** to ready your gun, **X** to shoot, and the **left stick** aims while the gun is up. The game's own LT to aim, RT to shoot still works.
- **Cannons and the mounted minigun:** the **left stick** aims as well as the right, and **X** fires as well as RT.
- **Playing as Ashley:** LT and RT both raise the lantern.

During ladders, cutscenes, the jet ski and other scripted moments, the mod steps aside and the game's normal controls apply.

## Known issues

- Turning on the spot uses Leon's standing turn animation, which looks a little stiff. The Remake doesn't have a proper turn-on-the-spot animation.
- Quick turns follow Leon's own turn animation, so they're slightly slower than the original's instant 180.
- Prompts show the game's own buttons, not the classic layout.

## Reporting problems

If something doesn't work, open the mod's menu and tick **Show debug info**. Click **Record 10 seconds** and reproduce the problem. This saves a file called `re4_tank_controls_record.json` in `reframework/data`. Include that file and a description of where in the game it happened.

Turn **Show debug info** off again afterwards. While it's on, the mod saves diagnostic files every session.
