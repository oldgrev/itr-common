# Builds the example map's navmesh and saves it into L_Example. Run after build_example.py, in the editor (not a
# commandlet: there the tiles don't reach the sublevel): File > Execute Python Script... > this file. Or unattended:
#   UE4Editor.exe <path>\IntoTheRadius.uproject -ExecCmds="py <path>\Scripts\build_navmesh.py" -ITRQuit
# (-ITRQuit closes the editor when done. Don't use -ExecutePythonScript=: it closes the editor as soon as the script
# returns, before the build runs.) Same as opening L_ExampleHost, Build > Build Paths, File > Save All.
import time

import unreal

HOST = "/Game/Mods/Example/L_ExampleHost"
ell = unreal.EditorLevelLibrary

ell.load_level(HOST)
world = ell.get_editor_world()
# The game's DefaultEngine.ini has bAutoCreateNavigationData=False, so the editor wouldn't create navmesh actors. Turn
# it on for this session and re-register the bounds volumes: the editor then creates RecastNavMesh-Default and
# RecastNavMesh-Big (one per agent in DefaultEngine.ini), the names the game's navmesh uses.
nav_sys = unreal.NavigationSystemV1.get_navigation_system(world)
nav_sys.set_editor_property("auto_create_navigation_data", True)
for b in [a for a in ell.get_all_level_actors() if isinstance(a, unreal.NavMeshBoundsVolume)]:
    nav_sys.on_navigation_bounds_updated(b)
unreal.SystemLibrary.execute_console_command(world, "RebuildNavigation")
state = {"start": time.monotonic(), "handle": None}


def tick(dt):
    world = ell.get_editor_world()
    elapsed = time.monotonic() - state["start"]
    # the build starts a few frames after the request; give it 10 s before trusting "not being built"
    if elapsed < 10.0 or unreal.NavigationSystemV1.is_navigation_being_built(world):
        return
    unreal.unregister_slate_post_tick_callback(state["handle"])
    ell.save_all_dirty_levels()
    navs = [a.get_name() for a in ell.get_all_level_actors() if isinstance(a, unreal.RecastNavMesh)]
    unreal.log("navmesh built and saved after %.0f s; navmesh actors: %s" % (elapsed, navs))
    if "-itrquit" in unreal.SystemLibrary.get_command_line().lower():
        unreal.SystemLibrary.quit_editor()


state["handle"] = unreal.register_slate_post_tick_callback(tick)
