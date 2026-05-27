--
-- DispatchSmokeTest.lua
-- v0.6 Smoke Test 2: end-to-end AI dispatch via vanilla AIJobLoadAndDeliver.
--
-- F9:
--   1. Spawns the Lizard Dragon (a self-contained grain truck with
--      fillUnit + dischargeNode built in) ahead of the player
--   2. Picks the nearest player-owned loadingStation with grain stock
--   3. Picks the closest unloadingStation that accepts the chosen fillType
--   4. Constructs AIJobLoadAndDeliver, validates, and calls
--      g_currentMission.aiSystem:startJob(job, playerFarmId)
--   5. Subscribes to MessageType.AI_JOB_STARTED / AI_JOB_STOPPED
--   6. Polls vehicle position + fillLevel + currentTaskIndex every 2s
--      and logs task transitions
--
-- ZERO coupling to v0.5 production code or to SmokeTest 1. Registers its
-- own mod-event-listener and input action. If F9 is never pressed, this
-- file's only observable effect is two log lines on save load.
--
-- Vanilla reference reads (from C:\dev\_scratch\FS25_vanilla):
--   dataS/scripts/ai/jobs/AIJobLoadAndDeliver.lua
--     L22-69   constructor; tasks + parameters
--     L73-171  setValues() binds vehicle + stations + fillType to tasks
--     L175-213 validate(farmId) — returns (isValid, errorMessage)
--     L232-254 applyCurrentState populates validUnloadingStations and
--              validLoadingStations from g_currentMission.storageSystem;
--              filters by accessHandler:canPlayerAccess + isa(UnloadingStation)
--              + station:getAISupportedFillTypes() ~= empty
--     L285-294 start(farmId) — calls vehicle:createAgent + aiJobStarted
--     L464-534 getIsAvailableForVehicle — vehicle must have createAgent,
--              setAITarget, getCanStartAIVehicle, getIsAIJobSupported,
--              non-empty getAIFillUnits AND getAIDischargeNodes (own or child)
--   dataS/scripts/ai/AISystem.lua
--     L540-549 startJob(job, startFarmId) — server-only; asserts isServer.
--              Broadcasts AIJobStartEvent and calls startJobInternal.
--     L554-559 startJobInternal — job:start(farmId), addJob, publishes
--              MessageType.AI_JOB_STARTED via g_messageCenter
--     L563-580 stopJob / stopJobInternal — publishes AI_JOB_STOPPED on stop
--   data/vehicles/lizard/multiPurposeTruck/multiPurposeTruck.xml —
--     the Lizard "Dragon" (file is named multiPurposeTruck but storeData.name
--     is "Dragon"). 85 KB XML, 6 fillUnit tags, 4 dischargeNodes, two
--     fillTypeCategories="BULK" compartments — base-game grain truck.
--     v0.5.99.2 used lizard/mks8 by mistake; that's a LIQUID tank
--     (MILK/WATER/LIQUIDFERTILIZER/HERBICIDE) — wrong vehicle entirely.
--
-- Acknowledged unknowns at write time:
--   - Whether the Dragon actually has the AIVehicle specialization at
--     spawn (the .xml itself doesn't declare it, but FS25 attaches specs
--     via vehicleTypes.xml at load time). If validation fails, we'll see
--     a clean error message from AIJobLoadAndDeliver:validate.
--   - Whether spawning a vehicle near the silo would path-find better
--     than spawning near the player. We spawn near the player for now
--     and log if AI fails to path; can iterate.
--

DispatchSmokeTest = {}
DispatchSmokeTest.MOD_NAME = g_currentModName or "FS25_GrainCollection"

DispatchSmokeTest.inputRegistered    = false
DispatchSmokeTest.dispatchInProgress = false
DispatchSmokeTest.dispatchCount      = 0

DispatchSmokeTest.activeVehicle      = nil
DispatchSmokeTest.activeJob          = nil
DispatchSmokeTest.lastTaskIndex      = nil
DispatchSmokeTest.lastFillLevel      = -1
DispatchSmokeTest.pollAccumulator    = 0

-- Legacy single-vehicle merchant truck (Lizard "Dragon"). Superseded by
-- the v0.6 FH16 + Krampe SKS 30/1050 bundle below; kept for reference.
DispatchSmokeTest.VEHICLE_XML        = "data/vehicles/lizard/multiPurposeTruck/multiPurposeTruck.xml"

-- v0.6 merchant vehicle: the FH16 + Krampe SKS 30/1050 bundle store
-- item registered by modDesc (vehicles/fh16KrampeBundle.xml). One
-- VehicleLoadingData load spawns BOTH, already attached. The store
-- item is resolved by matching this filename suffix / display name.
DispatchSmokeTest.BUNDLE_XML_SUFFIX  = "fh16KrampeBundle.xml"
DispatchSmokeTest.BUNDLE_NAME        = "Grain Haulier (FH16 + SKS 30/1050)"

-- v0.6: per-vehicle AutoDrive cornerSpeed setting index applied to the
-- merchant truck. AutoDrive.settings.cornerSpeed index 1 = 0.5 = "50%"
-- — corners taken at half AutoDrive's default cornering curve.
DispatchSmokeTest.AD_CORNER_SPEED_INDEX = 1

DispatchSmokeTest.POLL_INTERVAL_MS   = 2000

-- v0.5.99.4 / F10: world-relative spawn offset added to player position.
-- F10 spawns the truck at (playerX + x, terrain, playerZ + z). The y
-- component is currently unused — Y always clamps to terrain. Edit the
-- values here and reload the mod between runs to test different spawn
-- locations near a known silo entrance.
DispatchSmokeTest.OFFSET_VEC         = { x = 0, y = 0, z = 0 }

-- Own sequence number, used as a fallback in logs when job.jobId is nil.
DispatchSmokeTest.nextSeq            = 1
DispatchSmokeTest.activeJobSeq       = nil

-- v0.5.99.7 stuck-detector state (driveToLoading staying still).
DispatchSmokeTest.lastPosX           = nil
DispatchSmokeTest.lastPosZ           = nil
DispatchSmokeTest.stuckTickCount     = 0
DispatchSmokeTest.stuckDumpFired     = false
DispatchSmokeTest.STUCK_EPSILON_M    = 0.5
DispatchSmokeTest.STUCK_TICKS        = 3   -- 3 polls * POLL_INTERVAL_MS = ~6s

-- v0.5.99.10 per-frame snapshot accumulator. Faster than the main
-- pollState (2s) — we want sub-second resolution on the drive-to
-- limbo period between OFFSET_POS->FINAL_POS state switch and the
-- second (missing) onTargetReached.
DispatchSmokeTest.driveSnapshotAccumulator = 0
DispatchSmokeTest.DRIVE_SNAPSHOT_INTERVAL_MS = 1000

-- v0.5.99.12: per-tick AITaskLoading snapshot interval. The load task
-- is the focus of this build — once it becomes the current task we
-- want sub-second visibility into trigger state, fillUnit state, truck
-- speed, and the internal STATE_DRIVING/STATE_LOADING transition.
-- AITask:update (base class) is a no-op (AITask.lua:35), and
-- AITaskLoading does NOT override update — so our wrapped update on
-- the instance adds logging without changing any behaviour. Throttled
-- to 500 ms to give ~26 snapshots over a typical 13 s load attempt
-- without flooding logs at the ~60 Hz update rate.
DispatchSmokeTest.LOADING_UPDATE_INTERVAL_MS = 500

-- v0.5.99.21: the v0.5.99.13 force-stop "loading hold" was REMOVED.
-- It zeroed the truck's velocity for the whole of task[2], which froze
-- AITaskLoading's own STATE_DRIVING phase.
--
-- v0.5.99.22 selective drift clamp (Option B from the .21 retest
-- diagnosis). Without ANY hold the truck — carrying residual drive from
-- driveToLoading — accelerates to ~4.5 km/h and drives clean out of the
-- trigger before onTargetReached can fire. Option A (apply the brake)
-- was investigated and rejected: Drivable's brake/brakeToStop only runs
-- for player-entered vehicles (Drivable.lua:445-447), and Wheels:brake
-- gets overwritten every frame by AIVehicleUtil.driveToPoint ->
-- WheelsUtil.updateWheelsPhysics. So: clamp instead. The truck is free
-- to move within LOADING_CLAMP_EPSILON metres of where task[2] started
-- (room for AITaskLoading's sub-metre approach to its load target);
-- past that radius its velocity is zeroed every frame so it cannot
-- drive away. Engaged on task[2]:start, released on task[2]:stop.
DispatchSmokeTest.loadingClampEnabled   = false
DispatchSmokeTest.loadingClampStartX    = nil
DispatchSmokeTest.loadingClampStartZ    = nil
DispatchSmokeTest.LOADING_CLAMP_EPSILON = 1.0   -- metres of free movement

-- v0.5.99.27 multi-trip buyer-haulier config.
-- v0.5.99.29: SPAWN_POINT / DESPAWN_POINT are no longer hard-coded —
-- they are derived per-collection from the loading station's own AI
-- target node (queried via getAITargetPositionAndDirection). The spawn
-- is placed SPAWN_DISTANCE metres back from that node along the
-- approach axis, so it works on any map without per-save tuning.
DispatchSmokeTest.SPAWN_DISTANCE           = 50      -- metres back from the silo AI node
DispatchSmokeTest.BETWEEN_TRIPS_DELAY_MS   = 30000   -- pause between trips
DispatchSmokeTest.MAX_TRIPS                = 10      -- runaway guard
DispatchSmokeTest.PRICE_PER_LITRE_FALLBACK = 0.30    -- £/L if economy lookup fails

-- v0.5.99.31: proximity arrival. The direct-load flow doesn't need the
-- truck to physically dock — within ARRIVAL_RADIUS of the drive-to
-- target we declare "arrived" and force the task finished, so the AI
-- never attempts the tight final docking manoeuvre (which wedged the
-- truck against the silo in v0.5.99.30).
-- v0.5.99.32: 10 -> 20 m. Stopping further out leaves the truck open
-- space to U-turn for the drive back, instead of being boxed in near
-- the silo. A Lizard MultiPurpose (~5 m) needs only a few metres of
-- swing; 20 m is comfortable.
DispatchSmokeTest.ARRIVAL_RADIUS = 20    -- metres; force-finish a drive-to task within this
DispatchSmokeTest.proximityLogAcc = 0    -- throttle accumulator for the per-tick distance log

-- v0.5.99.27 collection (multi-trip) state. A "collection" is one F10
-- press: repeatedly spawn a truck, drive it to the silo, transfer up
-- to truck capacity, drive it back to DESPAWN_POINT, despawn, credit
-- money — until the silo is empty (or MAX_TRIPS).
DispatchSmokeTest.tripState                  = "idle"  -- idle | active | between-trips
DispatchSmokeTest.tripNumber                 = 0
DispatchSmokeTest.tripSaleDone               = false   -- did this trip reach doDirectSale?
DispatchSmokeTest.tripLoadedLitres           = 0       -- litres doDirectLoad actually pulled from the silo this trip
DispatchSmokeTest.betweenTripsTimer          = nil     -- ms remaining, or nil
DispatchSmokeTest.collectionLoadingStation   = nil
DispatchSmokeTest.collectionUnloadingStation = nil
DispatchSmokeTest.collectionFillType         = nil
DispatchSmokeTest.collectionTotalLitres      = 0
DispatchSmokeTest.collectionTotalPaid        = 0
DispatchSmokeTest.collectionSpawn            = nil   -- {x, z, dirX, dirZ} derived from the silo AI node
DispatchSmokeTest.collectionGrainStorage     = nil   -- the Storage/LoadingStation that actually holds the grain
DispatchSmokeTest.collectionGrainPlaceable   = nil   -- the silo placeable (its world pos = drive-to target)

-- v0.5.99.38 universal drive-target enforcement. A silo with no AI node
-- leaves driveTo*.x/.z unbound after setValues; we derive a target, but
-- vanilla's task lifecycle can wipe it. Rather than patch lifecycle
-- hooks, re-assert the derived target every frame (self-healing).
DispatchSmokeTest.needsTargetEnforcement     = false  -- true => silo has no AI node, enforce both drive legs
DispatchSmokeTest.enforceLoadTarget          = nil    -- {x, z, dirX, dirZ} for driveToLoadingTask
DispatchSmokeTest.enforceUnloadTarget        = nil    -- {x, z, dirX, dirZ} for driveToUnloadingTask

-- v0.6 AutoDrive driving path. AutoDrive replaces AIJobLoadAndDeliver as
-- the driving controller (vanilla AIJob rejects no-AI-node modded silos).
-- The direct-load / direct-sale / multi-trip architecture is unchanged —
-- only the thing that moves the truck swaps. USE_AUTODRIVE gates the two
-- paths so the old AIJob code stays callable until AutoDrive is proven.
DispatchSmokeTest.USE_AUTODRIVE     = true   -- false => legacy AIJobLoadAndDeliver
DispatchSmokeTest.AD_MATCH_RADIUS   = 50     -- m; max silo/buyer -> marker distance
DispatchSmokeTest.adLeg             = nil    -- nil | "to-silo" | "to-buyer"
DispatchSmokeTest.adLegTruck        = nil    -- the truck currently AutoDrive-driving
DispatchSmokeTest.adTrailer         = nil    -- the attached grain trailer (Krampe SKS) of the combo
DispatchSmokeTest.adSiloMarkerId    = nil    -- matched AutoDrive marker id for the silo
DispatchSmokeTest.adBuyerMarkerId   = nil    -- matched AutoDrive marker id for the buyer (proximity)
DispatchSmokeTest.adSpawnMarkerId   = nil    -- v0.6 restored: player's merchant-arrival marker (spawn only)
DispatchSmokeTest.adSiloMarkerPos   = nil    -- {x, z} of the silo marker (for arrival logging)
DispatchSmokeTest.adBuyerMarkerPos  = nil    -- {x, z} of the buyer marker
DispatchSmokeTest.adSpawnMarkerPos  = nil    -- {x, z} of the spawn (merchant arrival) marker
DispatchSmokeTest.adLegPollAcc      = 0      -- ms accumulator, throttles the progress log

-- v0.5.99.15 vanilla-flow observer state.
-- The user-confirmed vanilla Create Job > Load & Deliver flow works
-- end-to-end. We want to capture the full call sequence from that
-- working flow so we can diff against our broken F10 path. Approach:
-- wrap AIJobLoadAndDeliver.start at the CLASS level (so it fires for
-- every instance), gate the observation body on the global flag
-- `_G.gcObserveNext`. When the flag is true and an AIJobLoadAndDeliver
-- start fires, we capture that job and install the standard
-- DispatchSmokeTest hooks on it; flag flips false after one catch.
-- Two ways to arm: opening the Produce Collection (F7) menu OR
-- setting `gcObserveNext = true` in the in-game developer console.
-- Both write the same global. (Six keybind attempts were abandoned —
-- see installMenuObserverArm for the history.)
DispatchSmokeTest.OBSERVER_GLOBAL          = "gcObserveNext"
DispatchSmokeTest.vanillaObserverInstalled = false
DispatchSmokeTest.menuObserverArmInstalled = false
DispatchSmokeTest.observedJobs             = {}   -- weak set of jobs we've already hooked

-- v0.5.99.15 input diagnostics — retained even after the arm trigger
-- moved off the input system, because they answer "why did the
-- keybinds never fire" and remain useful reference instrumentation:
--  (1) raw keyEvent tap — mod-event-listeners receive keyEvent for
--      EVERY keyboard event the engine sees, regardless of whether an
--      action consumed it.
--  (2) 5s handler heartbeat — proves the update loop is alive.
--  (3) g_inputBinding introspection — best-effort dump of what's
--      registered, to spot another action shadowing a key.
DispatchSmokeTest.rawInputLogStart       = nil
DispatchSmokeTest.rawInputLogStopped     = false
DispatchSmokeTest.RAW_INPUT_LOG_DURATION = 30000   -- ms window after first key
DispatchSmokeTest.heartbeatAcc           = 0
DispatchSmokeTest.HEARTBEAT_INTERVAL     = 5000    -- ms

-- v0.5.99.8 task-lifecycle tracking. The user's screenshot shows the
-- truck is geometrically inside the load trigger AND the AI announces
-- "TARGET REACHED", but the load task never engages the trigger. The
-- vanilla flow that matters (AIJobLoadAndDeliver.lua:421-437):
--   driveToLoadingTask finishes -> job:getNextTaskIndex() is called
--   -> getNextTaskIndex iterates loadingNodeInfos and calls
--      loadingTask:setFillUnit(vehicle, fillUnitIndex, offsetZ) on the
--      FIRST entry whose fillUnitFillLevel == 0
--   -> returns loadingTask.taskIndex so the engine activates it
--   -> loadingTask:start() reads loadTrigger:getAITargetPositionAndDirection()
--      and calls vehicle:setAITarget(...) to drive to the trigger
--   -> when target reached, AITaskLoading:onTargetReached() (line 109)
--      requires self.loadVehicle ~= nil to call aiPrepareLoading and
--      aiStartLoadingFromTrigger. If setFillUnit never ran,
--      loadVehicle is nil and onTargetReached crashes silently.
-- We track every task's lifecycle every frame so we can answer:
--   - Was loadingTask ever started?
--   - Did its state change (DRIVING -> LOADING)?
--   - Were loadVehicle / fillUnitIndex set on it?
--   - Which task was current when the job stopped?
DispatchSmokeTest.taskLifecycle          = {}   -- [taskIndex] = {started=N, finished=N, lastIsRunning, lastIsFinished, lastState}
DispatchSmokeTest.lastTaskIndexSeen      = nil  -- updated every frame; gives us the "high watermark" current task
DispatchSmokeTest.lastLoadingTaskState   = nil
DispatchSmokeTest.lastLoadingTaskLoadVeh = nil  -- AITaskLoading.loadVehicle
DispatchSmokeTest.lastLoadingTaskFUI     = nil  -- AITaskLoading.fillUnitIndex
DispatchSmokeTest.lastLoadingTaskFT      = nil  -- AITaskLoading.fillType

local function logf(fmt, ...)
    print(string.format("[FS25_GrainCollection][SmokeTest2] " .. fmt, ...))
end

-- v0.5.99.8: resolve a task's class name. Direct reference comparison
-- against the job's named task slots always works; ClassUtil falls back
-- if we somehow see a task not on the known list. The post-setValues
-- dump in v0.5.99.7 was printing class=? because pcall(ClassUtil.getClassNameByObject)
-- returned an empty string on these task instances — direct comparison
-- side-steps whatever ClassUtil quirk is at play.
function DispatchSmokeTest:resolveTaskClass(t)
    if t == nil then return "<nil>" end
    local j = DispatchSmokeTest.activeJob
    if j ~= nil then
        if t == j.driveToLoadingTask   then return "AITaskDriveTo[load]"   end
        if t == j.loadingTask          then return "AITaskLoading"          end
        if t == j.driveToUnloadingTask then return "AITaskDriveTo[unload]" end
        if t == j.dischargeTask        then return "AITaskDischarge"       end
    end
    if ClassUtil ~= nil and ClassUtil.getClassNameByObject ~= nil then
        local ok, name = pcall(ClassUtil.getClassNameByObject, t)
        if ok and name and name ~= "" then return name end
    end
    return tostring(t)
end

-- v0.5.99.9: per-instance method wrapping for diagnostic visibility.
-- Vanilla AIJob:stop() (AIJob.lua:277-294) explicitly calls
-- self:resetTasks() — that's the canonical "wipe everything" path.
-- AIJobLoadAndDeliver:stop (AIJobLoadAndDeliver.lua:298-310) extends
-- that with `self.loadingNodeInfos = {}` / `self.dischargeNodeInfos = {}`.
-- AIJobLoadAndDeliver:getNextTaskIndex (line 421-437) is the ONLY site
-- that calls `loadingTask:setFillUnit(...)`, which is the ONLY thing
-- that populates loadingTask.loadVehicle/fillUnitIndex/offsetZ. If
-- getNextTaskIndex is never reached with currentTaskIndex ==
-- driveToLoadingTask.taskIndex, the load task can never start.
-- We wrap these methods on our instance only — vanilla code calling
-- via __index lookup hits our wrapper; subclass cascades via
-- AIJobLoadAndDeliver:superClass() are unaffected (they go through the
-- class metatable, not the instance).
function DispatchSmokeTest:wrapMethod(obj, methodName, opts)
    opts = opts or {}
    local orig = obj[methodName]
    if orig == nil then
        logf("[hook] cannot wrap %s.%s (not present)",
            tostring(opts.label or "obj"), methodName)
        return false
    end
    local label    = opts.label or ""
    local fullName = label .. methodName
    local withStack = opts.stack == true

    obj[methodName] = function(self, ...)
        local n = select("#", ...)
        local argstrs = {}
        for i = 1, math.min(n, 4) do
            table.insert(argstrs, tostring((select(i, ...))))
        end
        if n > 4 then table.insert(argstrs, "...") end

        logf("[hook] >> %s(%s)", fullName, table.concat(argstrs, ", "))
        if withStack then
            if debug ~= nil and debug.traceback ~= nil then
                local tb = debug.traceback("", 2)
                logf("[hook]    stack:%s", tostring(tb))
            elseif printCallstack ~= nil then
                pcall(printCallstack)
            end
        end

        local r1, r2, r3, r4 = orig(self, ...)
        -- Best-effort return-value log (up to 4). canContinueWork
        -- returns (bool, AIMessage). getNextTaskIndex returns int.
        -- start/stop return nothing.
        logf("[hook] << %s -> %s, %s, %s, %s",
            fullName,
            tostring(r1), tostring(r2), tostring(r3), tostring(r4))
        return r1, r2, r3, r4
    end
    return true
end

-- v0.5.99.10: snapshot of a task's mutable fields. Used to compare
-- before/after the original onTargetReached body, so we can prove
-- whether the OFFSET_POS->FINAL_POS state switch happened AND whether
-- isFinished was set.
function DispatchSmokeTest:snapshotDriveTo(t, label)
    if t == nil then logf("  %s: <nil>", label); return end
    local v = DispatchSmokeTest.activeVehicle
    local tx, _, tz = nil, nil, nil
    if v ~= nil and v.rootNode ~= nil then
        local ok, x, y, z = pcall(getWorldTranslation, v.rootNode)
        if ok then tx, _, tz = x, y, z end
    end
    local dist = "?"
    if tx and t.x and t.z then
        dist = string.format("%.2f", math.sqrt((tx - t.x)^2 + (tz - t.z)^2))
    end
    logf("  %s state=%s isFinished=%s isRunning=%s isActive=%s",
        label, tostring(t.state), tostring(t.isFinished),
        tostring(t.isRunning), tostring(t.isActive))
    logf("  %s target=(%s, %s) dir=(%s, %s) offset=%s",
        label, tostring(t.x), tostring(t.z),
        tostring(t.dirX), tostring(t.dirZ), tostring(t.offset))
    logf("  %s truck=(%s, %s) truck->target planar=%sm",
        label,
        tx and string.format("%.2f", tx) or "?",
        tz and string.format("%.2f", tz) or "?",
        dist)
end

-- v0.5.99.10: heavy hook on AITaskDriveTo:onTargetReached. The standard
-- wrapMethod just logs entry/exit args; this one snapshots task state
-- before AND after, so we can prove whether the OFFSET_POS branch
-- actually switched to FINAL_POS, whether isFinished flipped, AND
-- where the truck physically was during each fire. Critical because
-- the engine only emits onTargetReached when the AIVehicle decides
-- the truck has reached the target — if our two onTargetReached fires
-- happen with the truck at the same world position, that means the
-- AI vehicle thinks "I'm at the OFFSET pos and also at the FINAL pos"
-- which would tell us our offset is degenerate (offset==0 or target==offset_pos).
function DispatchSmokeTest:wrapDriveToOnTargetReached(t, label)
    local orig = t.onTargetReached
    if orig == nil then
        logf("[hook] cannot deep-wrap %s.onTargetReached (not present)", label)
        return
    end
    t.onTargetReached = function(self, ...)
        logf("[hook-deep] >> %sonTargetReached BEFORE:", label)
        DispatchSmokeTest:snapshotDriveTo(self, label .. "BEFORE")
        local r1, r2, r3, r4 = orig(self, ...)
        logf("[hook-deep] %sonTargetReached AFTER (orig returned %s, %s, %s, %s):",
            label, tostring(r1), tostring(r2), tostring(r3), tostring(r4))
        DispatchSmokeTest:snapshotDriveTo(self, label .. "AFTER ")
        return r1, r2, r3, r4
    end
end

-- v0.5.99.12: deep state snapshot for AITaskLoading. The user-observed
-- failure is task[2] (AITaskLoading) running 13s with fillLevel=0 — we
-- need answers to four questions on every interesting boundary:
--   1. Are loadVehicle / fillUnitIndex / fillType / loadTrigger all set?
--      (If any is nil, onTargetReached cannot fire aiStartLoadingFromTrigger.)
--   2. Is the truck physically inside the trigger? trigger.fillableObjects
--      is the authoritative answer — the engine writes to it from
--      loadTriggerCallback (LoadTrigger.lua:263) only when the truck's
--      collider overlaps the trigger volume AND fillUnit accepts the
--      trigger's fillType.
--   3. Does the trigger accept our fillType? getIsFillTypeSupported
--      (LoadTrigger.lua:677) returns whether trigger.fillTypes contains
--      our fillTypeIndex; this is what AITaskLoading.fillType is set to
--      by setValues.
--   4. Does the fillUnit have capacity for it? getFillUnitFreeCapacity
--      tells us whether there's room for more; getFillUnitAllowsFillType
--      validates the fillUnit↔fillType combination.
-- The 'reason' parameter labels the snapshot (start/onTargetReached/tick)
-- so the log is searchable per-event.
function DispatchSmokeTest:dumpLoadingTaskState(t, label, reason)
    if t == nil then logf("  %sdumpLoadingTaskState(%s): task is nil", label, tostring(reason)); return end
    local v  = DispatchSmokeTest.activeVehicle
    local lt = t.loadTrigger
    logf("  %s[%s] state=%s isFinished=%s isRunning=%s isLoadVehSet=%s",
        label, tostring(reason), tostring(t.state),
        tostring(t.isFinished), tostring(t.isRunning),
        tostring(t.loadVehicle ~= nil))

    local lv = t.loadVehicle
    logf("  %s[%s] loadVehicle=%s (==activeVehicle: %s) fillUnitIndex=%s offsetZ=%s",
        label, tostring(reason),
        tostring(lv), tostring(lv == v),
        tostring(t.fillUnitIndex), tostring(t.offsetZ))

    local ft = t.fillType and g_fillTypeManager
        and g_fillTypeManager:getFillTypeByIndex(t.fillType)
    logf("  %s[%s] fillType=%s (%s) loadTrigger=%s",
        label, tostring(reason),
        tostring(t.fillType), tostring(ft and ft.name or "?"),
        tostring(lt))

    -- Truck speed + position. Spec: AITaskLoading.lua:71-84 sets a new
    -- AITarget at the trigger position; the task can only enter
    -- STATE_LOADING via onTargetReached (line 109-117), so if the truck
    -- isn't moving toward / has overshot the new target, we'll see it.
    if v ~= nil then
        if v.getLastSpeed ~= nil then
            local okS, spd = pcall(v.getLastSpeed, v)
            logf("  %s[%s] truck speed=%s km/h",
                label, tostring(reason),
                okS and string.format("%.2f", spd or 0) or "?")
        end
        if v.rootNode ~= nil then
            local okP, x, _, z = pcall(getWorldTranslation, v.rootNode)
            if okP then
                logf("  %s[%s] truck pos=(%.2f, %.2f)", label, tostring(reason), x, z)
            end
        end
    end

    -- Trigger state. fillableObjects is the authoritative "is the truck
    -- physically inside" set; getIsFillableObjectAvailable is what the
    -- trigger itself checks before allowing startLoading.
    if lt ~= nil then
        if lt.fillableObjects ~= nil then
            local count, ourInside = 0, false
            for _, fo in pairs(lt.fillableObjects) do
                count = count + 1
                if fo.object == v then ourInside = true end
            end
            logf("  %s[%s] trigger.fillableObjects count=%d ourTruckInside=%s",
                label, tostring(reason), count, tostring(ourInside))
        else
            logf("  %s[%s] trigger.fillableObjects = nil", label, tostring(reason))
        end
        if lt.getIsFillableObjectAvailable ~= nil then
            local okA, avail = pcall(lt.getIsFillableObjectAvailable, lt)
            logf("  %s[%s] trigger:getIsFillableObjectAvailable() = %s",
                label, tostring(reason), okA and tostring(avail) or "err")
        end
        if lt.getAllowsActivation ~= nil and lv ~= nil then
            -- LoadTrigger.lua:512 — analogous to "getIsActivatable" the
            -- user asked about. Takes a fillableObject which the trigger
            -- normally finds in fillableObjects; we pass loadVehicle as
            -- a best-effort probe.
            local okGA, allows = pcall(lt.getAllowsActivation, lt, lv)
            logf("  %s[%s] trigger:getAllowsActivation(loadVeh) = %s",
                label, tostring(reason), okGA and tostring(allows) or "err")
        end
        if lt.getIsFillTypeSupported ~= nil and t.fillType ~= nil then
            local okT, ok = pcall(lt.getIsFillTypeSupported, lt, t.fillType)
            logf("  %s[%s] trigger:getIsFillTypeSupported(%s) = %s",
                label, tostring(reason), tostring(t.fillType),
                okT and tostring(ok) or "err")
        end
        -- LoadTrigger has an `isLoading` flag that flips to true while
        -- startLoading is dispensing (LoadTrigger.lua:498-510). If we
        -- see false during a "loading task is running" snapshot, the
        -- trigger was never told to start.
        logf("  %s[%s] trigger.isLoading=%s trigger.selectedFillType=%s currentFillType()=%s",
            label, tostring(reason),
            tostring(lt.isLoading),
            tostring(lt.selectedFillType),
            tostring(lt.getCurrentFillType and lt:getCurrentFillType() or "?"))
        -- v0.5.99.15: trigger-side fields that gate the load flow.
        --   source: trigger needs one (set via LoadTrigger:setSource); the
        --     source provides addFillLevelToFillableObject which trigger:update
        --     calls every tick while isLoading=true (LoadTrigger.lua:593).
        --   requiresActiveVehicle: true when automaticFilling is false
        --     (LoadTrigger.lua:201). Gates getAllowsActivation, which is
        --     consulted from getIsFillableObjectAvailable AND from
        --     onFillTypeSelection (player R path). FillUnit's vanilla
        --     getAllowLoadTriggerActivation returns true only if the
        --     local player is in this vehicle — AI-spawned trucks
        --     therefore fail the check, IF the AI code path consults it.
        --     v0.5.99.15 will reveal whether the AI path does or not.
        --   automaticFilling: if true, trigger:update auto-engages
        --     startLoading every 10 s when something is inside.
        --   validFillableObject / validFillableFillUnitIndex: set by
        --     getIsFillableObjectAvailable when it finds a valid candidate
        --     (LoadTrigger.lua:414). Required for onFillTypeSelection.
        --   currentFillableObject / fillUnitIndex: set by startLoading
        --     (line 531-532) — diagnostic for "did startLoading run".
        logf("  %s[%s] trigger.source=%s requiresActiveVehicle=%s automaticFilling=%s",
            label, tostring(reason),
            tostring(lt.source),
            tostring(lt.requiresActiveVehicle),
            tostring(lt.automaticFilling))
        logf("  %s[%s] trigger.validFillableObject=%s validFillUnitIndex=%s",
            label, tostring(reason),
            tostring(lt.validFillableObject),
            tostring(lt.validFillableFillUnitIndex))
        logf("  %s[%s] trigger.currentFillableObject=%s currentFillUnitIndex=%s",
            label, tostring(reason),
            tostring(lt.currentFillableObject),
            tostring(lt.fillUnitIndex))
        -- v0.5.99.15: probe vehicle:getAllowLoadTriggerActivation
        -- — vanilla FillUnit version is player-only (FillUnit.lua:1331).
        -- If the AI path uses an override or skips this entirely, the
        -- v0.5.99.15 logs will show both this probe value AND whether
        -- aiStartLoadingFromTrigger actually fires (hooked elsewhere).
        if lv ~= nil and lv.getAllowLoadTriggerActivation ~= nil then
            local okA, allow = pcall(lv.getAllowLoadTriggerActivation, lv, lv)
            logf("  %s[%s] loadVeh:getAllowLoadTriggerActivation() = %s",
                label, tostring(reason), okA and tostring(allow) or "err")
        end
    end

    -- fillUnit state. loadVehicle (not activeVehicle) is the one that
    -- the trigger fills — typically same as activeVehicle for single-
    -- compartment trucks, but the load job iterates loadingNodeInfos
    -- (AIJobLoadAndDeliver.lua:421-437) so multi-compartment vehicles
    -- can have loadVehicle = childVehicle.
    if lv ~= nil and t.fillUnitIndex ~= nil then
        if lv.getFillUnitCapacity ~= nil then
            local okC, c = pcall(lv.getFillUnitCapacity, lv, t.fillUnitIndex)
            logf("  %s[%s] fillUnit[%s] capacity=%s",
                label, tostring(reason), tostring(t.fillUnitIndex),
                okC and tostring(c) or "err")
        end
        if lv.getFillUnitFreeCapacity ~= nil then
            local okF, c = pcall(lv.getFillUnitFreeCapacity, lv, t.fillUnitIndex)
            logf("  %s[%s] fillUnit[%s] freeCapacity=%s",
                label, tostring(reason), tostring(t.fillUnitIndex),
                okF and tostring(c) or "err")
        end
        if lv.getFillUnitFillLevel ~= nil then
            local okL, c = pcall(lv.getFillUnitFillLevel, lv, t.fillUnitIndex)
            logf("  %s[%s] fillUnit[%s] fillLevel=%s",
                label, tostring(reason), tostring(t.fillUnitIndex),
                okL and tostring(c) or "err")
        end
        if lv.getFillUnitFillType ~= nil then
            local okT, c = pcall(lv.getFillUnitFillType, lv, t.fillUnitIndex)
            logf("  %s[%s] fillUnit[%s] currentFillType=%s",
                label, tostring(reason), tostring(t.fillUnitIndex),
                okT and tostring(c) or "err")
        end
        if lv.getFillUnitAllowsFillType ~= nil and t.fillType ~= nil then
            local okA, c = pcall(lv.getFillUnitAllowsFillType, lv, t.fillUnitIndex, t.fillType)
            logf("  %s[%s] fillUnit[%s] allowsFillType(%s)=%s",
                label, tostring(reason), tostring(t.fillUnitIndex),
                tostring(t.fillType), okA and tostring(c) or "err")
        end
    end

    -- v0.5.99.23: AIDrivable state. spec_aiDrivable is the spec that
    -- physically drives the truck to an AI target; spec.distanceToTarget
    -- is recomputed every AIDrivable:onUpdate (AIDrivable.lua:277) and
    -- onTargetReached fires when it drops below 0.5 m. Logging it on
    -- every task[2] snapshot shows whether the truck is converging on
    -- AITaskLoading's target or not — the step-2 break point from
    -- v0.6_TASK2_LOG_DIFF.md.
    if v ~= nil then
        local sd = v.spec_aiDrivable
        if sd ~= nil then
            logf("  %s[%s] aiDrivable: isRunning=%s useManualDriving=%s target=(%s, %s, %s) distanceToTarget=%s maxSpeed=%s task=%s",
                label, tostring(reason),
                tostring(sd.isRunning), tostring(sd.useManualDriving),
                tostring(sd.targetX), tostring(sd.targetY), tostring(sd.targetZ),
                tostring(sd.distanceToTarget), tostring(sd.maxSpeed),
                tostring(sd.task))
        else
            logf("  %s[%s] aiDrivable: spec_aiDrivable is NIL on the truck",
                label, tostring(reason))
        end
    end
end

-- v0.5.99.22 selective drift clamp helpers (Option B). See the state
-- declarations above for the rationale. The v13 hold helpers
-- (holdVehicleStationary / engageLoadingHold / tickLoadingHold /
-- releaseLoadingHold) were deleted in .21; these replace them with a
-- 1.0 m free-movement tolerance so AITaskLoading's own approach is not
-- blocked.

-- Zero linear + angular velocity on every rigid component (chassis +
-- any articulated segments). Native calls; precedent Baler.lua:2176.
-- Returns the component count actually zeroed.
local function gcZeroVehicleVelocity(v)
    if v == nil then return 0 end
    local n = 0
    if v.components ~= nil then
        for _, c in ipairs(v.components) do
            if c ~= nil and c.node ~= nil then
                if setLinearVelocity ~= nil then pcall(setLinearVelocity, c.node, 0, 0, 0) end
                if setAngularVelocity ~= nil then pcall(setAngularVelocity, c.node, 0, 0, 0) end
                n = n + 1
            end
        end
    end
    if n == 0 and v.rootNode ~= nil then
        if setLinearVelocity ~= nil then pcall(setLinearVelocity, v.rootNode, 0, 0, 0) end
        if setAngularVelocity ~= nil then pcall(setAngularVelocity, v.rootNode, 0, 0, 0) end
        n = 1
    end
    return n
end

-- Engage the clamp when task[2] starts: record the truck's position as
-- the anchor. No velocity change here — the truck is left free to move
-- the first LOADING_CLAMP_EPSILON metres (AITaskLoading's own approach).
function DispatchSmokeTest:engageLoadingClamp(v)
    DispatchSmokeTest.loadingClampEnabled = true
    DispatchSmokeTest.loadingClampStartX  = nil
    DispatchSmokeTest.loadingClampStartZ  = nil
    if v ~= nil and v.rootNode ~= nil then
        local okP, x, _, z = pcall(getWorldTranslation, v.rootNode)
        if okP then
            DispatchSmokeTest.loadingClampStartX = x
            DispatchSmokeTest.loadingClampStartZ = z
            logf("[clamp] engaged: anchor=(%.2f, %.2f) free-move radius=%.1fm",
                x, z, DispatchSmokeTest.LOADING_CLAMP_EPSILON)
        end
    end
end

-- Per-update-tick check. Inside the free-move radius: do nothing (let
-- AITaskLoading drive its sub-metre approach). Beyond it: zero velocity
-- every frame so the truck cannot drive out of the trigger.
function DispatchSmokeTest:tickLoadingClamp(v)
    if not DispatchSmokeTest.loadingClampEnabled then return end
    if v == nil or v.rootNode == nil then return end
    local okP, x, _, z = pcall(getWorldTranslation, v.rootNode)
    if not okP then return end
    local ax = DispatchSmokeTest.loadingClampStartX
    local az = DispatchSmokeTest.loadingClampStartZ
    if ax == nil or az == nil then
        DispatchSmokeTest.loadingClampStartX, DispatchSmokeTest.loadingClampStartZ = x, z
        return
    end
    local drift = math.sqrt((x - ax)^2 + (z - az)^2)
    if drift > DispatchSmokeTest.LOADING_CLAMP_EPSILON then
        local n = gcZeroVehicleVelocity(v)
        logf("[clamp] drift=%.2fm > %.1fm — zeroed velocity on %d component(s) (at %.2f, %.2f)",
            drift, DispatchSmokeTest.LOADING_CLAMP_EPSILON, n, x, z)
    end
end

-- Release the clamp when task[2] stops so driveToUnloading can move the
-- truck away from the silo unimpeded.
function DispatchSmokeTest:releaseLoadingClamp()
    if DispatchSmokeTest.loadingClampEnabled then
        logf("[clamp] released")
    end
    DispatchSmokeTest.loadingClampEnabled = false
    DispatchSmokeTest.loadingClampStartX  = nil
    DispatchSmokeTest.loadingClampStartZ  = nil
end

-- v0.5.99.12: deep wrap of AITaskLoading:start. The orig is short
-- (AITaskLoading.lua:71-84): sets self.state = STATE_DRIVING, calls
-- self.vehicle:setAITarget(self, x, y, z, ..., true), super.start.
-- We snapshot BEFORE (so we see what was bound by setFillUnit) and
-- AFTER (so we see what state and AITarget the orig produced).
function DispatchSmokeTest:wrapLoadingTaskStart(t, label)
    local orig = t.start
    if orig == nil then
        logf("[hook] cannot deep-wrap %sstart (not present)", label)
        return
    end
    t.start = function(self, ...)
        logf("[hook-deep] >> %sstart BEFORE:", label)
        DispatchSmokeTest:dumpLoadingTaskState(self, label, "start-BEFORE")
        local r1, r2, r3, r4 = orig(self, ...)
        logf("[hook-deep] %sstart AFTER (orig returned %s, %s, %s, %s):",
            label, tostring(r1), tostring(r2), tostring(r3), tostring(r4))
        DispatchSmokeTest:dumpLoadingTaskState(self, label, "start-AFTER ")
        -- v0.5.99.22: engage the drift clamp now that task[2] is running.
        DispatchSmokeTest:engageLoadingClamp(DispatchSmokeTest.activeVehicle)
        return r1, r2, r3, r4
    end
end

-- v0.5.99.13: deep wrap of AITaskLoading:stop for entry/exit logging.
-- (v0.5.99.21: it no longer releases a hold — the hold was deleted —
-- but the deep-wrap logging is kept as instrumentation.)
function DispatchSmokeTest:wrapLoadingTaskStop(t, label)
    local orig = t.stop
    if orig == nil then
        logf("[hook] cannot deep-wrap %sstop (not present)", label)
        return
    end
    t.stop = function(self, ...)
        local argstrs = {}
        local n = select("#", ...)
        for i = 1, math.min(n, 4) do
            table.insert(argstrs, tostring((select(i, ...))))
        end
        logf("[hook-deep] >> %sstop(%s)", label, table.concat(argstrs, ", "))
        local r1, r2, r3, r4 = orig(self, ...)
        logf("[hook-deep] << %sstop -> %s, %s, %s, %s",
            label, tostring(r1), tostring(r2), tostring(r3), tostring(r4))
        -- v0.5.99.22: release the drift clamp so driveToUnloading is free.
        DispatchSmokeTest:releaseLoadingClamp()
        return r1, r2, r3, r4
    end
end

-- v0.5.99.12: deep wrap of AITaskLoading:onTargetReached. The orig
-- (AITaskLoading.lua:109-117) is the ONLY site that:
--   * flips self.state to STATE_LOADING
--   * calls loadVehicle:aiPrepareLoading and aiStartLoadingFromTrigger
-- So if this never fires while task is current, the trigger is never
-- told to start filling — the smoking gun for "task runs 13s, fillLevel
-- stays 0". We snapshot before AND after so we can prove:
--   (a) whether the engine called us at all
--   (b) whether self.loadVehicle was nil (would silently break the
--       aiPrepareLoading call — orig doesn't pcall)
--   (c) whether state flipped from STATE_DRIVING to STATE_LOADING
--   (d) whether the trigger's isLoading flipped to true post-call
function DispatchSmokeTest:wrapLoadingTaskOnTargetReached(t, label)
    local orig = t.onTargetReached
    if orig == nil then
        logf("[hook] cannot deep-wrap %sonTargetReached (not present)", label)
        return
    end
    t.onTargetReached = function(self, ...)
        logf("[hook-deep] >> %sonTargetReached BEFORE:", label)
        DispatchSmokeTest:dumpLoadingTaskState(self, label, "onTargetReached-BEFORE")
        local r1, r2, r3, r4 = orig(self, ...)
        logf("[hook-deep] %sonTargetReached AFTER (orig returned %s, %s, %s, %s):",
            label, tostring(r1), tostring(r2), tostring(r3), tostring(r4))
        DispatchSmokeTest:dumpLoadingTaskState(self, label, "onTargetReached-AFTER ")
        return r1, r2, r3, r4
    end
end

-- v0.5.99.12: throttled per-tick wrap of AITaskLoading:update. AITask
-- (base) has an empty update body (AITask.lua:35), and AITaskLoading
-- does NOT override it — so our wrapper adds logging without altering
-- vanilla behaviour at all. The wrap only fires while task[2] is the
-- current task (AIJob:update at AIJob.lua:136 calls
-- currentTask:update(dt) on whichever task is active). Throttled by a
-- closure-local accumulator so we get one full state snapshot per
-- LOADING_UPDATE_INTERVAL_MS rather than one per frame (~60 Hz).
function DispatchSmokeTest:wrapLoadingTaskUpdate(t, label)
    local orig = t.update
    if orig == nil then
        logf("[hook] cannot wrap %supdate (not present)", label)
        return
    end
    local accumulator = 0
    local interval = DispatchSmokeTest.LOADING_UPDATE_INTERVAL_MS
    t.update = function(self, dt, ...)
        -- v0.5.99.22: drift clamp runs every frame task[2] is current.
        DispatchSmokeTest:tickLoadingClamp(DispatchSmokeTest.activeVehicle)
        accumulator = accumulator + (dt or 0)
        if accumulator >= interval then
            accumulator = accumulator - interval
            DispatchSmokeTest:dumpLoadingTaskState(self, label, "update-tick")
        end
        return orig(self, dt, ...)
    end
end

-- v0.5.99.15: hook every interesting method on the LoadTrigger
-- instance. The vanilla source (dataS/scripts/triggers/LoadTrigger.lua)
-- shows that trigger.isLoading is ONLY set true by startLoading
-- (line 526-545), which is only reached via setIsLoading(true, ...)
-- (line 498-508). Player R-key path goes through:
--    LoadTriggerActivatable:run → toggleLoading → onFillTypeSelection
--    → setIsLoading(true, ...) → startLoading → isLoading=true
-- AI path goes through:
--    AITaskLoading:onTargetReached
--      → loadVehicle:aiStartLoadingFromTrigger(trigger, fillUI, fillType, task)
--      → ???   (vehicle method body NOT in public dataS dump)
--      → eventually trigger.isLoading should flip true
-- If wrapping setIsLoading / startLoading / toggleLoading shows none
-- of them fire after onTargetReached, then aiStartLoadingFromTrigger
-- bypasses the trigger entirely (or doesn't exist on this vehicle).
function DispatchSmokeTest:wrapLoadTrigger(lt, label)
    if lt == nil then
        logf("[hook] no loadTrigger to wrap")
        return
    end
    label = label or "loadTrigger:"
    logf("[hook] installing LoadTrigger hooks (instance=%s)", tostring(lt))
    self:wrapMethod(lt, "setIsLoading",                { stack = true,  label = label })
    self:wrapMethod(lt, "startLoading",                { stack = true,  label = label })
    self:wrapMethod(lt, "stopLoading",                 { stack = true,  label = label })
    self:wrapMethod(lt, "toggleLoading",               { stack = true,  label = label })
    self:wrapMethod(lt, "onFillTypeSelection",         { stack = false, label = label })
    self:wrapMethod(lt, "getIsFillableObjectAvailable",{ stack = false, label = label })
    self:wrapMethod(lt, "getAllowsActivation",         { stack = false, label = label })
    self:wrapMethod(lt, "getIsFillTypeSupported",      { stack = false, label = label })
    -- raiseActive is also called from many sites — useful to know if
    -- the trigger is being woken at all.
    self:wrapMethod(lt, "raiseActive",                 { stack = false, label = label })
end

-- v0.5.99.15: hook the vehicle-side AI loading methods. These are
-- referenced by AITaskLoading:onTargetReached (aiPrepareLoading +
-- aiStartLoadingFromTrigger) and finishedLoading (aiFinishLoading)
-- but their function bodies are not in the public dataS dump (only
-- the Cover.lua overrides at Cover.lua:519-537 are visible). Hooking
-- the live instance lets us answer the open questions:
--   (1) Are these methods present at all on the spawned Lizard Dragon?
--   (2) Are they actually called by AITaskLoading at runtime?
--   (3) What does aiStartLoadingFromTrigger do — does it call back
--       into trigger:setIsLoading (caught by wrapLoadTrigger), or
--       go through a different code path?
function DispatchSmokeTest:wrapVehicleAILoadMethods(v, label)
    if v == nil then
        logf("[hook] no vehicle to wrap for AI load methods")
        return
    end
    label = label or "vehicle:"
    logf("[hook] installing vehicle AI-load hooks (instance=%s)", tostring(v))
    -- Probe presence first — these may not exist on every vehicle.
    local methods = {
        "aiStartLoadingFromTrigger",
        "aiPrepareLoading",
        "aiFinishLoading",
        "aiStoppedLoadingFromTrigger",
        "getAllowLoadTriggerActivation",
        "setFillUnitInTriggerRange",
    }
    for _, m in ipairs(methods) do
        local present = type(v[m]) == "function"
        logf("[hook] %s%s present=%s", label, m, tostring(present))
        if present then
            self:wrapMethod(v, m, { stack = false, label = label })
        end
    end
end

-- v0.5.99.23: deep instrumentation of the vehicle's AI driving API.
-- v0.6_TASK2_LOG_DIFF.md pinned the break at step 2 — the truck never
-- gets within 0.5 m of whatever target AITaskLoading sets. We have
-- never actually seen what setAITarget is told, nor confirmed the
-- spawned truck even carries spec_aiDrivable (the spec that owns
-- setAITarget + the onUpdate driveToPoint loop + reachedAITarget).
-- This wraps setAITarget / unsetAITarget on the truck instance and
-- probes its spec set. Pure instrumentation; no behaviour change.
function DispatchSmokeTest:wrapVehicleAIDriving(v)
    if v == nil then
        logf("[ai-drive] no vehicle to wrap for AI driving")
        return
    end
    logf("[ai-drive] installing AI-driving hooks (instance=%s)", tostring(v))

    -- (4) spec presence probe. If spec_aiDrivable is absent, nothing
    -- acts on the target AITaskLoading sets — that alone would explain
    -- the step-2 break.
    local specs = {
        "spec_aiDrivable", "spec_aiJobVehicle", "spec_aiLoadable",
        "spec_drivable", "spec_motorized", "spec_wheels", "spec_fillUnit",
    }
    for _, s in ipairs(specs) do
        logf("[ai-drive] %s present=%s", s, tostring(v[s] ~= nil))
    end

    -- (1) deep-wrap setAITarget. Signature (AIDrivable.lua:427):
    --   setAITarget(task, x, y, z, dirX, dirY, dirZ, maxSpeed, useManualDriving)
    if type(v.setAITarget) == "function" then
        local origSet = v.setAITarget
        v.setAITarget = function(self, task, x, y, z, dirX, dirY, dirZ, maxSpeed, useManualDriving, ...)
            logf("[ai-drive] >> setAITarget task=%s pos=(%s, %s, %s) dir=(%s, %s, %s) maxSpeed=%s useManualDriving=%s",
                tostring(task), tostring(x), tostring(y), tostring(z),
                tostring(dirX), tostring(dirY), tostring(dirZ),
                tostring(maxSpeed), tostring(useManualDriving))
            if printCallstack ~= nil then pcall(printCallstack) end
            local r1, r2, r3, r4 = origSet(self, task, x, y, z, dirX, dirY, dirZ, maxSpeed, useManualDriving, ...)
            logf("[ai-drive] << setAITarget -> %s, %s, %s, %s",
                tostring(r1), tostring(r2), tostring(r3), tostring(r4))
            local spec = self.spec_aiDrivable
            if spec ~= nil then
                logf("[ai-drive]    spec_aiDrivable post-setAITarget: isRunning=%s useManualDriving=%s target=(%s, %s, %s) maxSpeed=%s distanceToTarget=%s",
                    tostring(spec.isRunning), tostring(spec.useManualDriving),
                    tostring(spec.targetX), tostring(spec.targetY), tostring(spec.targetZ),
                    tostring(spec.maxSpeed), tostring(spec.distanceToTarget))
            else
                logf("[ai-drive]    spec_aiDrivable is NIL post-setAITarget — nothing will drive the truck to this target")
            end
            return r1, r2, r3, r4
        end
        logf("[ai-drive] setAITarget wrapped")
    else
        logf("[ai-drive] setAITarget NOT present — cannot wrap")
    end

    -- (2) deep-wrap unsetAITarget.
    if type(v.unsetAITarget) == "function" then
        local origUnset = v.unsetAITarget
        v.unsetAITarget = function(self, ...)
            logf("[ai-drive] >> unsetAITarget")
            if printCallstack ~= nil then pcall(printCallstack) end
            local r1, r2, r3, r4 = origUnset(self, ...)
            logf("[ai-drive] << unsetAITarget -> %s, %s, %s, %s",
                tostring(r1), tostring(r2), tostring(r3), tostring(r4))
            return r1, r2, r3, r4
        end
        logf("[ai-drive] unsetAITarget wrapped")
    else
        logf("[ai-drive] unsetAITarget NOT present — cannot wrap")
    end
end

-- =============================================================
-- v0.5.99.25 DIRECT-TRANSFER FLOW
-- =============================================================
-- Design pivot: the merchant truck no longer physically docks at the
-- silo / unload triggers. It drives to the loading-station area
-- (task[1] driveToLoading); grain transfers directly silo -> truck;
-- it drives to the unload-station area (task[3] driveToUnloading);
-- grain transfers directly truck -> unloadStation. task[2]
-- (AITaskLoading) and task[4] (AITaskDischarge) are skipped entirely
-- — no AI docking, no reverse driving, no trigger handshake.
--
-- Mechanism: override job.getNextTaskIndex. AIJob:update (AIJob.lua:146)
-- calls it each time a task finishes, with self.currentTaskIndex still
-- on the just-finished task. We intercept the two transitions:
--   currentTaskIndex == driveToLoadingTask  -> direct LOAD,
--       return driveToUnloadingTask.taskIndex  (skips task[2])
--   currentTaskIndex == driveToUnloadingTask -> direct UNLOAD,
--       return #tasks+1  -> AIJob:update calls
--       stopJob(AIMessageSuccessFinishedJob) (AIJob.lua:148-153)

-- Direct LOAD: silo grain Storage -> truck fill units.
-- v0.5.99.37: the grain source is the object GrainCollection:getOwnedSilos
-- discovered (DispatchSmokeTest.collectionGrainStorage) — the very same
-- object the F7 Produce Collection menu reads, so it is correct on
-- modded maps. It is normally a Storage, drained the way the mod's own
-- booking fulfilment drains it (GrainCollection.lua:1211):
--   Storage:getFillLevel(fillType) / Storage:setFillLevel(level, fillType)
-- A getOwnedSilos Path-2c entry can instead be a LoadingStation, which
-- exposes LoadingStation:removeFillLevel(fillType, delta, farmId). We
-- drain whichever it is and measure the litres actually given up from
-- the source level delta, so duplicate truck fill-unit indices cannot
-- inflate the trip total. Truck side: FillUnit:addFillUnitFillLevel
-- (FillUnit.lua:1485).
function DispatchSmokeTest:doDirectLoad(job)
    local src      = DispatchSmokeTest.collectionGrainStorage
        or (job.loadingStationParameter and job.loadingStationParameter:getLoadingStation())
    local fillType = job.fillTypeParameter and job.fillTypeParameter:getFillTypeIndex()
    local farmId   = g_currentMission and g_currentMission:getFarmId()
    local nodes    = job.loadingNodeInfos or {}
    if src == nil or fillType == nil or #nodes == 0 then
        logf("[direct-load] ABORT: grainSource=%s fillType=%s loadingNodeInfos=%d",
            tostring(src), tostring(fillType), #nodes)
        return
    end
    if src.getFillLevel == nil then
        logf("[direct-load] ABORT: grain source has no getFillLevel")
        return
    end
    local toolType = (ToolType ~= nil and ToolType.TRIGGER) or nil
    local ftDesc   = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillType)
    local ftName   = (ftDesc and ftDesc.name) or tostring(fillType)
    local srcKind  = (src.removeFillLevel ~= nil and "LoadingStation (removeFillLevel)")
        or (src.setFillLevel ~= nil and "Storage (setFillLevel)") or "unknown"
    logf("[direct-load] grain source = %s, fillType=%s, startLevel=%.0fL",
        srcKind, ftName, (src:getFillLevel(fillType, farmId)) or 0)

    for _, info in ipairs(nodes) do
        local v, fui = info.vehicle, info.fillUnitIndex
        if v ~= nil and fui ~= nil then
            local freeCap = (v.getFillUnitFreeCapacity and v:getFillUnitFreeCapacity(fui)) or 0
            local before  = (src:getFillLevel(fillType, farmId)) or 0
            local want    = math.min(freeCap, before)
            if want > 0 then
                -- Drain the silo FIRST; add to the truck only what the
                -- silo actually gave up (measured by the level delta).
                if src.removeFillLevel ~= nil then
                    local ok, err = pcall(src.removeFillLevel, src, fillType, want, farmId)
                    if not ok then logf("[direct-load] removeFillLevel failed: %s", tostring(err)) end
                elseif src.setFillLevel ~= nil then
                    local ok, err = pcall(src.setFillLevel, src, before - want, fillType)
                    if not ok then logf("[direct-load] setFillLevel failed: %s", tostring(err)) end
                else
                    logf("[direct-load] grain source exposes neither removeFillLevel nor setFillLevel")
                end
                local afterSrc = (src:getFillLevel(fillType, farmId)) or 0
                local removed  = before - afterSrc
                local tBefore  = (v.getFillUnitFillLevel and v:getFillUnitFillLevel(fui)) or 0
                if removed > 0 and v.addFillUnitFillLevel ~= nil then
                    local ok, err = pcall(v.addFillUnitFillLevel, v, farmId, fui, removed, fillType, toolType, nil)
                    if not ok then logf("[direct-load] addFillUnitFillLevel failed: %s", tostring(err)) end
                end
                local tAfter = (v.getFillUnitFillLevel and v:getFillUnitFillLevel(fui)) or 0
                -- v0.5.99.28: accumulate the authoritative amount actually
                -- taken FROM THE SILO (the source level delta cannot be
                -- fooled by duplicate fillUnit indices).
                DispatchSmokeTest.tripLoadedLitres = DispatchSmokeTest.tripLoadedLitres + removed
                logf("[direct-load] fillUnit%d: want=%.0fL siloGave=%.0fL truckTook=%.0fL newTruckLevel=%.0fL siloLeft=%.0fL",
                    fui, want, removed, tAfter - tBefore, tAfter, afterSrc)
            else
                logf("[direct-load] fillUnit%d: nothing to transfer (freeCap=%.0fL siloLevel=%.0fL)",
                    fui, freeCap, before)
            end
        end
    end
end

-- Direct UNLOAD: truck fill units -> unloadStation. UnloadingStation's
-- add-fill API is not in the public dataS dump (the file is stripped),
-- so the destination add is best-effort: try station:addFillLevel,
-- then storage iteration (targetStorages/sourceStorages/storages —
-- mirrors LoadingStation:removeFillLevel + GrainCollection.lua's own
-- proven storage:setFillLevel drain). Whatever path works is logged;
-- if none do, the station's field names are dumped for the next pass.
function DispatchSmokeTest:doDirectUnload(job)
    local station  = job.unloadingStationParameter and job.unloadingStationParameter:getUnloadingStation()
    local fillType = job.fillTypeParameter and job.fillTypeParameter:getFillTypeIndex()
    local farmId   = g_currentMission and g_currentMission:getFarmId()
    local nodes    = job.loadingNodeInfos or {}
    if station == nil or fillType == nil then
        logf("[direct-unload] ABORT: station=%s fillType=%s", tostring(station), tostring(fillType))
        return
    end
    local toolType    = (ToolType ~= nil and ToolType.TRIGGER) or nil
    local stationName = (station.getName and station:getName()) or "?"

    -- Remove all grain from the truck.
    local removedFromTruck = 0
    for _, info in ipairs(nodes) do
        local v, fui = info.vehicle, info.fillUnitIndex
        if v ~= nil and fui ~= nil and v.getFillUnitFillLevel ~= nil then
            local before = v:getFillUnitFillLevel(fui) or 0
            if before > 0 and v.addFillUnitFillLevel ~= nil then
                pcall(v.addFillUnitFillLevel, v, farmId, fui, -before, fillType, toolType, nil)
                local after = v:getFillUnitFillLevel(fui) or 0
                removedFromTruck = removedFromTruck + (before - after)
            end
        end
    end
    if removedFromTruck <= 0 then
        logf("[direct-unload] truck is empty — nothing to unload")
        return
    end

    -- Add to the unload destination — best effort.
    local addedToStation, method = 0, "none"
    if station.addFillLevel ~= nil then
        local ok = pcall(station.addFillLevel, station, farmId, removedFromTruck, fillType)
        if ok then addedToStation, method = removedFromTruck, "station:addFillLevel" end
    end
    if method == "none" then
        for _, fieldName in ipairs({ "targetStorages", "sourceStorages", "storages" }) do
            local storages = station[fieldName]
            if type(storages) == "table" then
                local left = removedFromTruck
                for _, storage in pairs(storages) do
                    if left > 0 and storage.getFillLevel ~= nil and storage.setFillLevel ~= nil then
                        local cur  = storage:getFillLevel(fillType) or 0
                        local cap  = (storage.getCapacity and storage:getCapacity(fillType)) or math.huge
                        local put  = math.min(left, math.max(cap - cur, 0))
                        if put > 0 then
                            pcall(storage.setFillLevel, storage, cur + put, fillType)
                            left = left - put
                            addedToStation = addedToStation + put
                        end
                    end
                end
                if addedToStation > 0 then method = "storage(" .. fieldName .. ")"; break end
            end
        end
    end
    if method == "none" then
        local keys = {}
        for k, val in pairs(station) do table.insert(keys, tostring(k) .. ":" .. type(val)) end
        table.sort(keys)
        logf("[direct-unload] no add path found on unloadStation. fields: %s", table.concat(keys, ", "))
    end
    logf("[direct-unload] to='%s' removedFromTruck=%.0fL addedToStation=%.0fL via=%s",
        tostring(stationName), removedFromTruck, addedToStation, method)
end

-- Override job.getNextTaskIndex on this job instance to run the
-- direct-transfer flow and skip task[2] / task[4].
function DispatchSmokeTest:installDirectFlow(job)
    if job == nil or type(job.getNextTaskIndex) ~= "function" then
        logf("[direct-flow] cannot install — job.getNextTaskIndex missing")
        return
    end
    local orig = job.getNextTaskIndex
    job.getNextTaskIndex = function(self, ...)
        local cti = self.currentTaskIndex
        if job.driveToLoadingTask ~= nil and cti == job.driveToLoadingTask.taskIndex then
            logf("[direct-flow] task[1] driveToLoading finished — direct LOAD, skipping task[2] AITaskLoading")
            pcall(DispatchSmokeTest.doDirectLoad, DispatchSmokeTest, job)
            local idx = job.driveToUnloadingTask and job.driveToUnloadingTask.taskIndex
            logf("[direct-flow] getNextTaskIndex -> %s (driveToUnloading)", tostring(idx))
            return idx
        elseif job.driveToUnloadingTask ~= nil and cti == job.driveToUnloadingTask.taskIndex then
            logf("[direct-flow] task[3] drive-back finished (truck at DESPAWN_POINT) — direct SALE, skipping task[4]")
            pcall(DispatchSmokeTest.doDirectSale, DispatchSmokeTest, job)
            local idx = #self.tasks + 1
            logf("[direct-flow] getNextTaskIndex -> %d (> #tasks -> job completes)", idx)
            return idx
        end
        return orig(self, ...)
    end
    logf("[direct-flow] job.getNextTaskIndex overridden — direct-transfer flow active")
end

function DispatchSmokeTest:installHooks(job)
    if job == nil then return end
    logf("[hook] installing diagnostic hooks on job + tasks")

    -- v0.5.99.10: identity sanity checks. If task.job is not OUR job
    -- instance, onTargetReached's path to "tell the parent" is broken.
    -- AITask.new(isServer, job, ...) stores `self.job = job` (AITask.lua:20).
    -- The engine doesn't actually use task.job to advance — it uses
    -- AIJob:update which checks currentTask:getIsFinished() directly.
    -- But verifying still rules out a bizarre instance-substitution bug.
    if job.tasks ~= nil then
        for i, t in ipairs(job.tasks) do
            local sameRef    = (t == job.tasks[i])
            local jobMatches = (t.job == job)
            logf("[identity] task[%d](%s) sameRefInTable=%s task.job==job=%s task.job=%s ourJob=%s",
                i, self:resolveTaskClass(t),
                tostring(sameRef), tostring(jobMatches),
                tostring(t.job), tostring(job))
        end
    end
    -- The driveToLoadingTask is the one stuck. Snapshot its state right
    -- now, before the engine starts touching it, so we have a baseline.
    if job.driveToLoadingTask ~= nil then
        logf("[identity] driveToLoadingTask same as job.tasks[1]: %s",
            tostring(job.driveToLoadingTask == job.tasks[1]))
        self:snapshotDriveTo(job.driveToLoadingTask, "driveToLoadingTask(install) ")
    end

    -- Job-level methods. setValues / resetTasks / stop are the ones
    -- that wipe state — attach stack traces so we can see WHO is
    -- calling them.
    self:wrapMethod(job, "setValues",         { stack = true,  label = "job:" })
    self:wrapMethod(job, "resetTasks",        { stack = true,  label = "job:" })
    self:wrapMethod(job, "stop",              { stack = true,  label = "job:" })
    self:wrapMethod(job, "start",             { stack = false, label = "job:" })
    self:wrapMethod(job, "startTask",         { stack = false, label = "job:" })
    self:wrapMethod(job, "stopTask",          { stack = true,  label = "job:" })
    self:wrapMethod(job, "getNextTaskIndex",  { stack = false, label = "job:" })
    self:wrapMethod(job, "canContinueWork",   { stack = false, label = "job:" })
    self:wrapMethod(job, "canStartWork",      { stack = false, label = "job:" })
    self:wrapMethod(job, "getStartTaskIndex", { stack = false, label = "job:" })

    -- Per-task hooks. reset is the destructive one — log stack. start
    -- proves the engine actually activated the task. stop proves it
    -- was deactivated.
    --
    -- v0.5.99.12: AITaskLoading now gets the full deep-wrap treatment:
    --   * start            -> wrapLoadingTaskStart (snapshot before/after)
    --   * onTargetReached  -> wrapLoadingTaskOnTargetReached (ditto)
    --   * update(dt)       -> wrapLoadingTaskUpdate (throttled 500ms snapshot)
    -- Plus every other AITaskLoading method gets the standard lightweight
    -- entry/exit wrap so we know exactly which methods the engine calls
    -- and in what order.
    if job.tasks ~= nil then
        for i, t in ipairs(job.tasks) do
            local taskLabel = string.format("task[%d](%s):", i,
                self:resolveTaskClass(t))
            self:wrapMethod(t, "reset", { stack = true, label = taskLabel })

            -- stop: deep wrap for loadingTask (releases v0.5.99.13 hold);
            -- other tasks keep the lightweight stack-tracing wrap.
            if t == job.loadingTask then
                self:wrapLoadingTaskStop(t, taskLabel)
            else
                self:wrapMethod(t, "stop", { stack = true, label = taskLabel })
            end

            -- start: deep wrap for loadingTask only — that's the v0.5.99.12
            -- focus. Other tasks keep the lightweight entry/exit log.
            if t == job.loadingTask then
                self:wrapLoadingTaskStart(t, taskLabel)
            else
                self:wrapMethod(t, "start", { stack = false, label = taskLabel })
            end

            -- onTargetReached: deep wrap for driveToLoading (v0.5.99.10)
            -- and loadingTask (v0.5.99.12). Other tasks keep lightweight.
            if t == job.driveToLoadingTask then
                self:wrapDriveToOnTargetReached(t, taskLabel)
                self:wrapMethod(t, "setTargetPosition",  { stack = true,  label = taskLabel })
                self:wrapMethod(t, "setTargetDirection", { stack = true,  label = taskLabel })
                self:wrapMethod(t, "setTargetOffset",    { stack = true,  label = taskLabel })
                self:wrapMethod(t, "startDriving",       { stack = false, label = taskLabel })
            elseif t == job.loadingTask then
                self:wrapLoadingTaskOnTargetReached(t, taskLabel)
            else
                self:wrapMethod(t, "onTargetReached", { stack = false, label = taskLabel })
            end

            -- AITaskLoading-only methods (vanilla source:
            -- dataS/scripts/ai/tasks/AITaskLoading.lua).
            if t == job.loadingTask then
                self:wrapLoadingTaskUpdate(t, taskLabel)
                self:wrapMethod(t, "setVehicle",       { stack = false, label = taskLabel })
                self:wrapMethod(t, "setFillUnit",      { stack = false, label = taskLabel })
                self:wrapMethod(t, "setLoadTrigger",   { stack = false, label = taskLabel })
                self:wrapMethod(t, "setFillType",      { stack = false, label = taskLabel })
                self:wrapMethod(t, "finishedLoading",  { stack = false, label = taskLabel })
                self:wrapMethod(t, "onError",          { stack = true,  label = taskLabel })
                self:wrapMethod(t, "skip",             { stack = true,  label = taskLabel })
            end
        end
    end

    -- v0.5.99.15: hook the actual LoadTrigger instance and the
    -- spawned vehicle's AI-load methods. Trigger reference comes
    -- from job.loadingTask.loadTrigger (bound by setValues at
    -- AIJobLoadAndDeliver.lua:157). Vehicle is DispatchSmokeTest
    -- .activeVehicle — the truck we just spawned. These hooks tell
    -- us which side of the AI→trigger handshake is failing when
    -- trigger.isLoading never flips.
    local lt = job.loadingTask and job.loadingTask.loadTrigger
    self:wrapLoadTrigger(lt, "loadTrigger:")
    self:wrapVehicleAILoadMethods(DispatchSmokeTest.activeVehicle, "loadVeh:")

    -- v0.5.99.25: install the direct-transfer flow (skips task[2]/task[4]).
    self:installDirectFlow(job)

    logf("[hook] hook install complete")
end

-- =============================================================
-- Mod lifecycle
-- =============================================================

-- v0.5.99.15 observer flag helpers. Single source of truth is
-- _G.gcObserveNext so the in-game console can flip it directly with
-- `gcObserveNext = true`. Opening the Produce Collection (F7) menu
-- mirrors that path (see installMenuObserverArm).
local function gcGetObserverFlag()
    return _G[DispatchSmokeTest.OBSERVER_GLOBAL] == true
end

local function gcSetObserverFlag(v)
    _G[DispatchSmokeTest.OBSERVER_GLOBAL] = v and true or false
end

-- v0.5.99.15+: in-game toast helper. Uses the same notification
-- channel AIJob:showNotification uses (AIJob.lua:362) — appears as
-- a non-modal banner at the top of the screen, auto-dismisses.
-- "ok" = green, "info" = blue, "critical" = red. pcall-wrapped so
-- a missing API never breaks the smoke test.
local function gcToast(text, severity)
    if g_currentMission == nil or g_currentMission.addIngameNotification == nil then return end
    if FSBaseMission == nil then return end
    local kind = FSBaseMission.INGAME_NOTIFICATION_OK
    if severity == "info" then
        kind = FSBaseMission.INGAME_NOTIFICATION_INFO
    elseif severity == "critical" then
        kind = FSBaseMission.INGAME_NOTIFICATION_CRITICAL
    end
    pcall(g_currentMission.addIngameNotification, g_currentMission, kind, text)
end

-- v0.5.99.15: class-level wrap of AIJobLoadAndDeliver.start. Fires for
-- EVERY instance, including jobs created by the vanilla GUI flow.
-- The body only runs when the observer is armed (Produce Collection
-- menu open or `gcObserveNext = true` in console); auto-disarms after
-- the first catch so we don't keep grabbing every subsequent AI dispatch.
--
-- Installed ONCE, at loadMap time. The base class is loaded as soon as
-- the game starts, well before any mod's loadMap, so it's safe to
-- assume AIJobLoadAndDeliver exists here.
function DispatchSmokeTest:installVanillaJobObserver()
    if DispatchSmokeTest.vanillaObserverInstalled then return end
    if AIJobLoadAndDeliver == nil or type(AIJobLoadAndDeliver.start) ~= "function" then
        logf("[observer] AIJobLoadAndDeliver.start not available — observer disabled")
        return
    end
    DispatchSmokeTest.vanillaObserverInstalled = true
    local origStart = AIJobLoadAndDeliver.start
    AIJobLoadAndDeliver.start = function(self, farmId, ...)
        if gcGetObserverFlag() and not DispatchSmokeTest.observedJobs[self] then
            gcSetObserverFlag(false)
            DispatchSmokeTest.observedJobs[self] = true

            gcToast("GrainCollection: vanilla AIJobLoadAndDeliver CAUGHT — hooks installed", "ok")
            logf("==========================================================")
            logf("[observer] CAUGHT vanilla AIJobLoadAndDeliver:start")
            logf("[observer]   job instance     = %s", tostring(self))
            logf("[observer]   farmId           = %s", tostring(farmId))
            local v  = self.vehicleParameter         and self.vehicleParameter:getVehicle()                 or nil
            local ls = self.loadingStationParameter  and self.loadingStationParameter:getLoadingStation()   or nil
            local us = self.unloadingStationParameter and self.unloadingStationParameter:getUnloadingStation() or nil
            local ftIdx = self.fillTypeParameter     and self.fillTypeParameter:getFillTypeIndex()          or nil
            local ft = ftIdx and g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(ftIdx) or nil
            logf("[observer]   vehicle          = %s", tostring(v))
            logf("[observer]   loadingStation   = %s (%s)",
                tostring(ls), ls and tostring(ls:getName()) or "?")
            logf("[observer]   unloadingStation = %s (%s)",
                tostring(us), us and tostring(us:getName()) or "?")
            logf("[observer]   fillType         = %s (%s)",
                tostring(ftIdx), tostring(ft and ft.name or "?"))
            logf("[observer]   isDirectStart    = %s", tostring(self.isDirectStart))
            logf("[observer]   jobTypeIndex     = %s", tostring(self.jobTypeIndex))
            logf("[observer]   isLooping        = %s",
                tostring(self.loopingParameter and self.loopingParameter:getIsLooping()))
            logf("==========================================================")

            -- Adopt this job into DispatchSmokeTest tracking, but only
            -- if no F10 dispatch is already running — don't clobber an
            -- in-progress smoke test. When adopted, the per-frame
            -- pollState / trackTaskLifecycle / trackLoadingTaskFields
            -- machinery (gated on activeJob+activeVehicle in update())
            -- runs for the observed vanilla job too, giving us the
            -- same heartbeat coverage as F10 dispatch.
            if DispatchSmokeTest.activeJob == nil then
                DispatchSmokeTest.activeVehicle    = v
                DispatchSmokeTest.activeJob        = self
                DispatchSmokeTest.lastTaskIndex    = self.currentTaskIndex
                DispatchSmokeTest.lastFillLevel    = -1
                DispatchSmokeTest.pollAccumulator  = 0
                DispatchSmokeTest.activeJobSeq     = DispatchSmokeTest.nextSeq
                DispatchSmokeTest.nextSeq          = DispatchSmokeTest.nextSeq + 1
                DispatchSmokeTest.taskLifecycle    = {}
                DispatchSmokeTest.lastTaskIndexSeen      = self.currentTaskIndex
                DispatchSmokeTest.lastLoadingTaskState   = self.loadingTask and self.loadingTask.state
                DispatchSmokeTest.lastLoadingTaskLoadVeh = self.loadingTask and self.loadingTask.loadVehicle
                DispatchSmokeTest.lastLoadingTaskFUI     = self.loadingTask and self.loadingTask.fillUnitIndex
                DispatchSmokeTest.lastLoadingTaskFT      = self.loadingTask and self.loadingTask.fillType
                logf("[observer] adopted as activeJob (seq=%d) — polling/snapshots ENABLED for this job",
                    DispatchSmokeTest.activeJobSeq)
            else
                logf("[observer] DispatchSmokeTest.activeJob already set — NOT adopting (existing F10 job still tracked); hooks still install on the observed job")
            end

            -- Install the standard diagnostic hooks. This wraps the
            -- per-instance start/stop/update/onTargetReached etc. on
            -- this job, the trigger, and (if not already an active
            -- F10 vehicle) the vehicle's AI-load methods. The class
            -- wrapper is BEFORE the orig — so by the time orig runs,
            -- the per-instance start wrap is in place and will fire
            -- on this same call... wait, no — wrapMethod replaces
            -- obj.start AFTER we entered this closure, so this call's
            -- orig(...) below goes straight to AIJob's real start.
            -- That's fine: the deep wrap is for FUTURE start calls,
            -- but the per-task wraps (loadingTask, etc.) and the
            -- trigger / vehicle wraps catch everything that happens
            -- AFTER this start returns. We DO miss the start-BEFORE
            -- snapshot on the observed job. Acceptable trade-off.
            local ok, err = pcall(DispatchSmokeTest.installHooks, DispatchSmokeTest, self)
            if not ok then
                logf("[observer] installHooks threw: %s", tostring(err))
            end
        end
        return origStart(self, farmId, ...)
    end
    logf("[observer] AIJobLoadAndDeliver.start wrapper installed (arm by opening the Produce Collection F7 menu, or `gcObserveNext = true` in console)")
end

-- v0.5.99.15: arm the observer. Single entry point — sets the flag,
-- logs, and emits the green toast. `source` is a short label for the
-- log line (e.g. "menu") so we can tell where the arm came from.
function DispatchSmokeTest:armObserver(source)
    gcSetObserverFlag(true)
    logf("[observer] %s — gcObserveNext armed; next AIJobLoadAndDeliver:start will be hooked",
        tostring(source or "?"))
    gcToast("GrainCollection: vanilla job observer ARMED — next Load and Deliver job will be hooked", "ok")
end

-- v0.5.99.15: class-level wrap of InGameMenuProduceCollection.onFrameOpen.
-- After six failed keybind attempts (F12/F6/Insert/backslash/less — the
-- last reached raw input but the action handler still never fired) the
-- arm trigger moved off the input system entirely. Opening the Produce
-- Collection tab (F7 menu) now arms the observer. The observer is
-- one-shot (disarms itself after catching one job), so re-arming on
-- every menu open is harmless. Wrapping the CLASS method means every
-- frame instance is covered regardless of when it was created; we just
-- have to wrap before the first open, which loadMap guarantees.
function DispatchSmokeTest:installMenuObserverArm()
    if DispatchSmokeTest.menuObserverArmInstalled then return end
    if InGameMenuProduceCollection == nil
            or type(InGameMenuProduceCollection.onFrameOpen) ~= "function" then
        logf("[observer] InGameMenuProduceCollection.onFrameOpen not available — menu arm disabled")
        return
    end
    DispatchSmokeTest.menuObserverArmInstalled = true
    local origOnFrameOpen = InGameMenuProduceCollection.onFrameOpen
    InGameMenuProduceCollection.onFrameOpen = function(self, ...)
        origOnFrameOpen(self, ...)
        -- Arm AFTER the frame's own open logic, pcall-guarded, so an
        -- error in arm code can never break the production menu.
        pcall(DispatchSmokeTest.armObserver, DispatchSmokeTest, "menu")
    end
    logf("[observer] InGameMenuProduceCollection.onFrameOpen wrapped — opening the Produce Collection (F7) tab arms the observer")
end

-- v0.5.99.15 DIAGNOSTIC: raw keyboard tap. addModEventListener-registered
-- tables receive keyEvent(unicode, sym, modifier, isDown) for every
-- keyboard event the engine processes. We log key-down events for a
-- 30s window after the first key (window starts lazily so it captures
-- the user actually testing, not the loading screen). Retained as
-- reference instrumentation after the arm trigger moved to the menu:
-- it was this tap that proved the UK/EU \ key emits sym=60 (KEY_less),
-- and that even a correctly-bound action can reach raw input yet never
-- fire its handler — which is why the keybind approach was abandoned.
function DispatchSmokeTest:keyEvent(unicode, sym, modifier, isDown)
    if DispatchSmokeTest.rawInputLogStopped then return end
    local now = g_time or 0
    if DispatchSmokeTest.rawInputLogStart == nil then
        DispatchSmokeTest.rawInputLogStart = now
        logf("[raw-input] keyEvent tap ACTIVE — logging key-downs for %dms",
            DispatchSmokeTest.RAW_INPUT_LOG_DURATION)
    end
    if now - DispatchSmokeTest.rawInputLogStart > DispatchSmokeTest.RAW_INPUT_LOG_DURATION then
        DispatchSmokeTest.rawInputLogStopped = true
        logf("[raw-input] tap window expired — no more raw keyEvent logs this session")
        return
    end
    if isDown then
        -- Input.keyIdToIdName maps sym -> readable name on most FS builds;
        -- fall back to the numeric sym if the table isn't present.
        local keyName = "?"
        if Input ~= nil and type(Input.keyIdToIdName) == "table" then
            keyName = tostring(Input.keyIdToIdName[sym] or sym)
        else
            keyName = tostring(sym)
        end
        logf("[raw-input] keyEvent down: sym=%s name=%s unicode=%s modifier=%s",
            tostring(sym), keyName, tostring(unicode), tostring(modifier))
    end
end

-- v0.5.99.15 DIAGNOSTIC: best-effort dump of the input-binding system.
-- Field/method names in g_inputBinding are not all documented in the
-- public dump, so this probes defensively: dump top-level structure,
-- count actionEvents, and surface every actionEvent entry whose
-- resolvable action name mentions our observer action or "INSERT".
-- Whatever it prints, the next iteration can be refined from it.
function DispatchSmokeTest:probeInsertBindings()
    if g_inputBinding == nil then
        logf("[probe] g_inputBinding is nil — cannot introspect bindings")
        return
    end

    -- Top-level structure, one-shot, so we know what tables exist.
    local topKeys = {}
    for k, v in pairs(g_inputBinding) do
        table.insert(topKeys, string.format("%s:%s", tostring(k), type(v)))
    end
    table.sort(topKeys)
    logf("[probe] g_inputBinding fields: %s", table.concat(topKeys, ", "))

    -- Probe for plausible introspection methods.
    local methodNames = {
        "getActionEventsByActionName", "getActionEvent", "getActionMapping",
        "getActionBinding", "getKeyMappingsForActionBinding",
        "getDisplayKeyNamesForActionBinding", "getActionInputName",
    }
    local foundMethods = {}
    for _, m in ipairs(methodNames) do
        if type(g_inputBinding[m]) == "function" then
            table.insert(foundMethods, m)
        end
    end
    logf("[probe] g_inputBinding introspection methods present: %s",
        #foundMethods > 0 and table.concat(foundMethods, ", ") or "(none of the probed names)")

    -- Walk actionEvents. Layout varies by FS build; handle both
    -- numeric-id-keyed and name-keyed tables, and dump any entry that
    -- looks related to our action or the Insert key.
    local ae = g_inputBinding.actionEvents
    if type(ae) == "table" then
        local count = 0
        for key, entry in pairs(ae) do
            count = count + 1
            if type(entry) == "table" then
                -- Resolve a name from whatever field carries it.
                local nm = entry.actionName or entry.name
                    or (type(key) == "string" and key) or nil
                if nm ~= nil then
                    local s = tostring(nm)
                    if s:find("GRAINCOLLECTION") or s:upper():find("INSERT") then
                        logf("[probe] actionEvents entry key=%s actionName=%s",
                            tostring(key), s)
                        -- Dump the entry's own fields for cross-reference
                        -- against a known-working binding (F9/F10).
                        local fields = {}
                        for fk, fv in pairs(entry) do
                            table.insert(fields, string.format("%s:%s=%s",
                                tostring(fk), type(fv), tostring(fv)))
                        end
                        table.sort(fields)
                        logf("[probe]   fields: %s", table.concat(fields, " | "))
                    end
                end
            end
        end
        logf("[probe] g_inputBinding.actionEvents total entries: %d", count)
    else
        logf("[probe] g_inputBinding.actionEvents is %s (not a table)", type(ae))
    end

    -- If the engine exposes a name->event map keyed by action, dump
    -- the GRAINCOLLECTION ones from there too.
    local nmeKeys = { "nameActionEvents", "actionEventsByName", "events" }
    for _, fieldName in ipairs(nmeKeys) do
        local t = g_inputBinding[fieldName]
        if type(t) == "table" then
            logf("[probe] g_inputBinding.%s exists (%d entries) — scanning for GRAINCOLLECTION",
                fieldName, (function() local n=0 for _ in pairs(t) do n=n+1 end return n end)())
            for k, _ in pairs(t) do
                local s = tostring(k)
                if s:find("GRAINCOLLECTION") then
                    logf("[probe]   %s[%s] present", fieldName, s)
                end
            end
        end
    end
end

function DispatchSmokeTest:loadMap(name)
    logf("loadMap fired — F9 will register on first update tick")
    -- Subscribe to AI lifecycle messages so we get the START / STOP edges
    -- even if our polling misses them between ticks.
    if g_messageCenter ~= nil and MessageType ~= nil then
        if MessageType.AI_JOB_STARTED ~= nil then
            g_messageCenter:subscribe(MessageType.AI_JOB_STARTED,
                DispatchSmokeTest.onAIJobStarted, DispatchSmokeTest)
        end
        if MessageType.AI_JOB_STOPPED ~= nil then
            g_messageCenter:subscribe(MessageType.AI_JOB_STOPPED,
                DispatchSmokeTest.onAIJobStopped, DispatchSmokeTest)
        end
    end
    -- v0.5.99.15: arm the class-level vanilla observer. Dormant
    -- (no behaviour change) until the observer is armed.
    pcall(DispatchSmokeTest.installVanillaJobObserver, DispatchSmokeTest)
    -- v0.5.99.15: install the menu-open arm trigger (replaces the
    -- never-working keybind). Opening the Produce Collection tab arms
    -- the observer for the next AIJobLoadAndDeliver:start.
    pcall(DispatchSmokeTest.installMenuObserverArm, DispatchSmokeTest)
end

function DispatchSmokeTest:update(dt)
    if not DispatchSmokeTest.inputRegistered then
        if g_currentMission ~= nil and g_inputBinding ~= nil
                and InputAction ~= nil
                and InputAction.GRAINCOLLECTION_SMOKETEST_DISPATCH ~= nil
                and InputAction.GRAINCOLLECTION_SMOKETEST_DISPATCH_OFFSET ~= nil then
            local ok, err = pcall(function()
                local s1, id1 = g_inputBinding:registerActionEvent(
                    InputAction.GRAINCOLLECTION_SMOKETEST_DISPATCH,
                    DispatchSmokeTest, DispatchSmokeTest.onDispatchInput,
                    false, true, false, true)
                if s1 then
                    g_inputBinding:setActionEventTextVisibility(id1, false)
                    logf("F9 input registered (eventId=%s)", tostring(id1))
                else
                    logf("F9 register FAILED")
                end
                local s2, id2 = g_inputBinding:registerActionEvent(
                    InputAction.GRAINCOLLECTION_SMOKETEST_DISPATCH_OFFSET,
                    DispatchSmokeTest, DispatchSmokeTest.onDispatchOffsetInput,
                    false, true, false, true)
                if s2 then
                    g_inputBinding:setActionEventTextVisibility(id2, false)
                    logf("F10 input registered (eventId=%s) offset=(%.1f, %.1f, %.1f)",
                        tostring(id2),
                        DispatchSmokeTest.OFFSET_VEC.x or 0,
                        DispatchSmokeTest.OFFSET_VEC.y or 0,
                        DispatchSmokeTest.OFFSET_VEC.z or 0)
                else
                    logf("F10 register FAILED")
                end
                -- v0.5.99.15: the observer arm is NO LONGER a keybind.
                -- Six keybind attempts (F12, F6, Insert, KEY_backslash,
                -- KEY_less) all failed the same way: the action either
                -- conflicted, needed a modifier the keyboard couldn't
                -- send, or — for KEY_less — reached raw input but the
                -- action handler still never fired. The arm trigger has
                -- moved to the Produce Collection (F7) menu: opening
                -- that tab arms the observer. See installMenuObserverArm.
            end)
            if not ok then
                logf("F9/F10 register threw: %s", tostring(err))
            end
            DispatchSmokeTest.inputRegistered = true
            -- v0.5.99.15 DIAGNOSTIC: dump binding-system state right
            -- after our registrations. Retained as reference
            -- instrumentation now that the observer arm is menu-driven.
            pcall(DispatchSmokeTest.probeInsertBindings, DispatchSmokeTest)
        end
    end

    -- v0.5.99.15 DIAGNOSTIC: 5s heartbeat. Confirms the update loop +
    -- handler are alive even when no key press is being detected.
    DispatchSmokeTest.heartbeatAcc = DispatchSmokeTest.heartbeatAcc + (dt or 0)
    if DispatchSmokeTest.heartbeatAcc >= DispatchSmokeTest.HEARTBEAT_INTERVAL then
        DispatchSmokeTest.heartbeatAcc = DispatchSmokeTest.heartbeatAcc
            - DispatchSmokeTest.HEARTBEAT_INTERVAL
        logf("[observer] handler-alive — observer arms on Produce Collection (F7) menu open; armed=%s",
            tostring(gcGetObserverFlag()))
    end

    -- v0.5.99.27: between-trips delay countdown. When it elapses, the
    -- next trip's truck is spawned.
    if DispatchSmokeTest.tripState == "between-trips"
            and DispatchSmokeTest.betweenTripsTimer ~= nil then
        DispatchSmokeTest.betweenTripsTimer = DispatchSmokeTest.betweenTripsTimer - (dt or 0)
        if DispatchSmokeTest.betweenTripsTimer <= 0 then
            DispatchSmokeTest.betweenTripsTimer = nil
            logf("[collection] between-trips delay elapsed — dispatching next trip")
            pcall(DispatchSmokeTest.startNextTrip, DispatchSmokeTest)
        end
    end

    -- v0.6: AutoDrive driving — per-frame leg poll + transitions.
    -- Self-gates on adLeg; no-op when the AutoDrive path is idle.
    pcall(DispatchSmokeTest.updateAutoDrive, DispatchSmokeTest, dt)

    -- v0.5.99.5: task-transition detection runs every frame so we catch
    -- short-lived task switches (e.g. driveToLoading -> loading that
    -- completes in <2s). The slower 2s pollState logs fill-level + idle
    -- "still on task X" so we see progress on long-running tasks.
    if DispatchSmokeTest.activeJob ~= nil and DispatchSmokeTest.activeVehicle ~= nil then
        local j = DispatchSmokeTest.activeJob
        local taskIdx = j.currentTaskIndex
        if taskIdx ~= DispatchSmokeTest.lastTaskIndex then
            local fromName = DispatchSmokeTest:taskName(DispatchSmokeTest.lastTaskIndex)
            local toName   = DispatchSmokeTest:taskName(taskIdx)
            logf("[transition] %s (idx=%s) -> %s (idx=%s)",
                fromName, tostring(DispatchSmokeTest.lastTaskIndex),
                toName, tostring(taskIdx))
            DispatchSmokeTest.lastTaskIndex = taskIdx
        end
        -- v0.5.99.8: cache the live currentTaskIndex so AI_JOB_STOPPED
        -- can report which task was running at the moment of the stop.
        if taskIdx ~= nil then
            DispatchSmokeTest.lastTaskIndexSeen = taskIdx
        end

        -- v0.5.99.8: per-frame lifecycle tracking. Records started/finished
        -- counters per task and logs state changes, so we can answer
        -- "did the load task ever enter STATE_LOADING" without polling
        -- timing luck.
        pcall(DispatchSmokeTest.trackTaskLifecycle, DispatchSmokeTest)
        pcall(DispatchSmokeTest.trackLoadingTaskFields, DispatchSmokeTest)

        -- v0.5.99.38: re-assert our derived drive-to target every frame
        -- (silos with no AI node only). Runs BEFORE checkProximityArrival
        -- so the task's x/z are restored before the distance is measured.
        pcall(DispatchSmokeTest.enforceDriveTargets, DispatchSmokeTest, dt)

        -- v0.5.99.31: proximity arrival — force-finish a drive-to task
        -- once the truck is within ARRIVAL_RADIUS of its target.
        pcall(DispatchSmokeTest.checkProximityArrival, DispatchSmokeTest, dt)

        DispatchSmokeTest.pollAccumulator = DispatchSmokeTest.pollAccumulator + (dt or 0)
        if DispatchSmokeTest.pollAccumulator >= DispatchSmokeTest.POLL_INTERVAL_MS then
            DispatchSmokeTest.pollAccumulator = 0
            local pollOk, pollErr = pcall(DispatchSmokeTest.pollState, DispatchSmokeTest)
            if not pollOk then logf("pollState EXCEPTION: %s", tostring(pollErr)) end
        end

        -- v0.5.99.10: 1Hz snapshot of driveToLoadingTask state + truck
        -- distance to target, ONLY while task[1] is current. This is
        -- the limbo we're investigating: state switches to FINAL_POS
        -- but the second onTargetReached never fires. The snapshot
        -- shows whether the truck is actively making progress toward
        -- the FINAL target or has stalled.
        DispatchSmokeTest.driveSnapshotAccumulator =
            DispatchSmokeTest.driveSnapshotAccumulator + (dt or 0)
        if DispatchSmokeTest.driveSnapshotAccumulator >=
                DispatchSmokeTest.DRIVE_SNAPSHOT_INTERVAL_MS then
            DispatchSmokeTest.driveSnapshotAccumulator = 0
            if j.driveToLoadingTask ~= nil
                    and j.currentTaskIndex == j.driveToLoadingTask.taskIndex then
                DispatchSmokeTest:snapshotDriveTo(
                    j.driveToLoadingTask, "[drive-snap] driveToLoading ")
            end
        end
    end
end

-- v0.5.99.8: per-task lifecycle tracker. Called every frame while a job
-- is active. For each task in job.tasks we keep a record of how many
-- times we've observed it transition into isRunning=true and into
-- isFinished=true. Also logs every internal `state` change (e.g.
-- AITaskLoading STATE_DRIVING -> STATE_LOADING) — that's the smoking
-- gun for "did the load task ever start filling?"
function DispatchSmokeTest:trackTaskLifecycle()
    local j = DispatchSmokeTest.activeJob
    if j == nil or j.tasks == nil then return end
    for _, t in ipairs(j.tasks) do
        local idx = t.taskIndex
        if idx ~= nil then
            local rec = DispatchSmokeTest.taskLifecycle[idx]
            if rec == nil then
                rec = { started = 0, finished = 0,
                        lastIsRunning = false, lastIsFinished = false,
                        lastState = t.state }
                DispatchSmokeTest.taskLifecycle[idx] = rec
            end
            local cls = DispatchSmokeTest:resolveTaskClass(t)
            if t.isRunning and not rec.lastIsRunning then
                rec.started = rec.started + 1
                logf("[lifecycle] task[%d] (%s) START #%d",
                    idx, cls, rec.started)
            end
            if t.isFinished and not rec.lastIsFinished then
                rec.finished = rec.finished + 1
                logf("[lifecycle] task[%d] (%s) FINISH #%d",
                    idx, cls, rec.finished)
            end
            if t.state ~= rec.lastState then
                logf("[lifecycle] task[%d] (%s) state %s -> %s",
                    idx, cls, tostring(rec.lastState), tostring(t.state))
                rec.lastState = t.state
            end
            rec.lastIsRunning  = t.isRunning
            rec.lastIsFinished = t.isFinished
        end
    end
end

-- v0.5.99.8: log every change of the AITaskLoading fields that determine
-- whether onTargetReached can fire successfully. setFillUnit (called
-- from job:getNextTaskIndex during a driveToLoading -> loading transition)
-- writes loadVehicle + fillUnitIndex + offsetZ. If these stay nil, we
-- know getNextTaskIndex never selected a loading node for this fillUnit.
function DispatchSmokeTest:trackLoadingTaskFields()
    local j = DispatchSmokeTest.activeJob
    local lt = j and j.loadingTask
    if lt == nil then return end
    if lt.state ~= DispatchSmokeTest.lastLoadingTaskState then
        logf("[loadingTask] state %s -> %s",
            tostring(DispatchSmokeTest.lastLoadingTaskState), tostring(lt.state))
        DispatchSmokeTest.lastLoadingTaskState = lt.state
    end
    if lt.loadVehicle ~= DispatchSmokeTest.lastLoadingTaskLoadVeh then
        logf("[loadingTask] loadVehicle %s -> %s (set by getNextTaskIndex)",
            tostring(DispatchSmokeTest.lastLoadingTaskLoadVeh),
            tostring(lt.loadVehicle))
        DispatchSmokeTest.lastLoadingTaskLoadVeh = lt.loadVehicle
    end
    if lt.fillUnitIndex ~= DispatchSmokeTest.lastLoadingTaskFUI then
        logf("[loadingTask] fillUnitIndex %s -> %s",
            tostring(DispatchSmokeTest.lastLoadingTaskFUI),
            tostring(lt.fillUnitIndex))
        DispatchSmokeTest.lastLoadingTaskFUI = lt.fillUnitIndex
    end
    if lt.fillType ~= DispatchSmokeTest.lastLoadingTaskFT then
        local ft = lt.fillType and g_fillTypeManager:getFillTypeByIndex(lt.fillType)
        logf("[loadingTask] fillType %s -> %s (%s)",
            tostring(DispatchSmokeTest.lastLoadingTaskFT),
            tostring(lt.fillType), tostring(ft and ft.name or "?"))
        DispatchSmokeTest.lastLoadingTaskFT = lt.fillType
    end
end

-- =============================================================
-- F9 input handler
-- =============================================================

local function guardForDispatch(label)
    if g_currentMission == nil or not g_currentMission:getIsClient() then return false end
    if DispatchSmokeTest.dispatchInProgress then
        logf("dispatch already in progress, ignoring %s", label)
        return false
    end
    if DispatchSmokeTest.activeJob ~= nil then
        logf("previous job still active (taskIndex=%s), ignoring %s — wait for job to stop",
            tostring(DispatchSmokeTest.activeJob.currentTaskIndex), label)
        return false
    end
    return true
end

-- v0.5.99.27: F9 and F10 both start a multi-trip COLLECTION. The truck
-- spawns at SPAWN_POINT, drives to the silo, loads, drives back to
-- DESPAWN_POINT, despawns, money is credited — repeated until the silo
-- is empty (or MAX_TRIPS). The old single-shot / offset-spawn handlers
-- are gone; spawn is always SPAWN_POINT now.
function DispatchSmokeTest:startCollection(label)
    if g_currentMission == nil or not g_currentMission:getIsClient() then return end
    if DispatchSmokeTest.tripState ~= "idle" then
        logf("%s: collection already running (state=%s, trip %d) — ignoring",
            label, DispatchSmokeTest.tripState, DispatchSmokeTest.tripNumber)
        return
    end
    if DispatchSmokeTest.dispatchInProgress or DispatchSmokeTest.activeJob ~= nil then
        logf("%s: a dispatch/job is still active — ignoring", label)
        return
    end

    local farmId = g_currentMission:getFarmId()
    local grainSet = self:getGrainFillTypeSet()
    -- v0.5.99.37: findLoadingStation now also returns the grain Storage
    -- object (drained directly in doDirectLoad) and the silo placeable
    -- (its world position is the drive-to target — modded silos have no
    -- AI node, so getAITargetPositionAndDirection returns nil).
    local loadingStation, fillLevel, fillTypeIndex, grainStorage, grainPlaceable =
        self:findLoadingStation(farmId)
    if loadingStation == nil then
        -- findLoadingStation only considers grain fill types, so nil here
        -- means no grain silo on the map (e.g. a lime quarry).
        logf("%s ABORT: no grain silo with stock found — mod collects grain only", label)
        gcToast("No grain silos available for collection", "critical")
        return
    end
    -- Belt-and-braces: the chosen fill type must be grain.
    if grainSet[fillTypeIndex] == nil then
        logf("%s ABORT: chosen fillType %s is not grain", label, tostring(fillTypeIndex))
        gcToast("Mod only collects grain (Barley, Canola, Oat, Wheat)", "critical")
        return
    end

    -- v0.5.99.30: spawn/despawn point = the player-placed pickup
    -- location for this farm (set with F9 — stand at the spot, press
    -- F9). Persisted per-farm in the savegame XML by GrainCollection.
    local pickup = nil
    if GrainCollection ~= nil and GrainCollection.getPickupLocation ~= nil then
        pickup = GrainCollection:getPickupLocation(farmId)
    end
    if pickup == nil then
        logf("%s ABORT: no pickup location set for farm %s — stand at the spot and press F9 first",
            label, tostring(farmId))
        gcToast("Set a pickup location first: stand at the spot and press F9", "critical")
        return
    end
    DispatchSmokeTest.collectionSpawn =
        { x = pickup.x, z = pickup.z, dirX = pickup.dirX, dirZ = pickup.dirZ }
    logf("[collection] pickup location (player-set): spawn=(%.1f, %.1f) dir=(%.2f, %.2f)",
        pickup.x, pickup.z, pickup.dirX, pickup.dirZ)

    --[[ v0.7 fallback — auto-derive the spawn from the silo's AI target
         node when no pickup location has been placed. Kept for v0.7:
    local sx, sz, sdx, sdz
    if loadingStation.getAITargetPositionAndDirection ~= nil then
        local ok, x, z, dx, dz = pcall(loadingStation.getAITargetPositionAndDirection,
            loadingStation, fillTypeIndex)
        if ok then sx, sz, sdx, sdz = x, z, dx, dz end
    end
    if sx ~= nil and sz ~= nil and sdx ~= nil and sdz ~= nil then
        local dist = DispatchSmokeTest.SPAWN_DISTANCE
        DispatchSmokeTest.collectionSpawn =
            { x = sx - sdx * dist, z = sz - sdz * dist, dirX = sdx, dirZ = sdz }
    end
    ]]

    -- Pick the buyer once, up front, so it is stable across all trips.
    local unloadingStation, _, pickLabel = self:findUnloadingStation(
        fillTypeIndex, farmId, pickup.x, pickup.z, loadingStation)
    if unloadingStation == nil then
        logf("%s ABORT: no unloadingStation accepts the fill type", label)
        return
    end

    DispatchSmokeTest.collectionLoadingStation   = loadingStation
    DispatchSmokeTest.collectionUnloadingStation = unloadingStation
    DispatchSmokeTest.collectionFillType         = fillTypeIndex
    DispatchSmokeTest.collectionGrainStorage     = grainStorage
    DispatchSmokeTest.collectionGrainPlaceable   = grainPlaceable
    DispatchSmokeTest.collectionTotalLitres      = 0
    DispatchSmokeTest.collectionTotalPaid        = 0
    DispatchSmokeTest.tripNumber                 = 0
    DispatchSmokeTest.dispatchCount = DispatchSmokeTest.dispatchCount + 1

    local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    logf("[collection] %s #%d START: loadingStation='%s' fillType='%s' siloLevel=%.0fL buyer='%s' (pick=%s)",
        label, DispatchSmokeTest.dispatchCount,
        tostring(loadingStation:getName()),
        tostring(ft and ft.title or fillTypeIndex),
        fillLevel,
        tostring(unloadingStation:getName()), tostring(pickLabel))
    if pickLabel == "fallback-same" then
        logf("[collection] WARN: buyer is the same placeable as the silo (no separate buyer found)")
    end

    -- v0.6 step 2: match the silo + buyer to AutoDrive markers up front,
    -- before spawning anything. If either has no marker in range, abort
    -- the whole collection now with a clear toast.
    if DispatchSmokeTest.USE_AUTODRIVE then
        if not DispatchSmokeTest:matchADMarkers() then
            DispatchSmokeTest:endCollection("no AutoDrive markers")
            return
        end
    end

    DispatchSmokeTest:startNextTrip()
end

-- v0.6: player-facing collection entry, wired to the Produce Collection
-- menu's BOOK (row) click. Unlike startCollection (the F10 dev path),
-- the fill type + buyer come from the clicked row, and the truck spawns
-- at the BUYER's AutoDrive marker (buyer-originated flow, Option A) —
-- it drives buyer -> silo -> buyer. Returns (ok, message) so the menu
-- can surface feedback. AutoDrive is always the driving controller here.
function DispatchSmokeTest:startCollectionFromMenu(row)
    if g_currentMission == nil or not g_currentMission:getIsClient() then
        return false, "Not in an active game"
    end
    if row == nil or row.fillTypeIndex == nil then
        return false, "Invalid produce row"
    end
    if DispatchSmokeTest.tripState ~= "idle"
            or DispatchSmokeTest.dispatchInProgress
            or DispatchSmokeTest.activeJob ~= nil then
        logf("[BOOK] collection already running (state=%s, trip %d) — ignoring",
            tostring(DispatchSmokeTest.tripState), DispatchSmokeTest.tripNumber)
        return false, "A collection is already in progress"
    end

    local farmId        = g_currentMission:getFarmId()
    local fillTypeIndex = row.fillTypeIndex
    local ft     = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local ftName = (ft and ft.title) or tostring(fillTypeIndex)

    -- Grain-only guard (the haulier collects grain).
    local grainSet = self:getGrainFillTypeSet()
    if grainSet[fillTypeIndex] == nil then
        return false, "Only grain can be collected (Barley, Canola, Oat, Wheat)"
    end

    -- v0.6: the merchant arrival marker (per farm) is the SPAWN point
    -- only — despawn happens at the buyer marker. If unset, return
    -- needsPicker=true so the menu opens the marker picker rather than
    -- dispatching to a bad point.
    local merchantId = nil
    if GrainCollection ~= nil and GrainCollection.getMerchantMarker ~= nil then
        merchantId = GrainCollection:getMerchantMarker(farmId)
    end
    if merchantId == nil then
        return false, "Choose a merchant arrival point first", true
    end

    -- The buyer is the row's best buyer — not a proximity pick.
    local buyer = row.bestBuyerStation
    if buyer == nil or not row.hasSellPoint then
        return false, "No buyer available for " .. ftName
    end

    -- The silo holding THIS fill type (most stock).
    local loadingStation, fillLevel, _, grainStorage, grainPlaceable =
        self:findLoadingStation(farmId, fillTypeIndex)
    if loadingStation == nil then
        return false, "No reachable silo holds " .. ftName
    end

    DispatchSmokeTest.collectionLoadingStation   = loadingStation
    DispatchSmokeTest.collectionUnloadingStation = buyer
    DispatchSmokeTest.collectionFillType         = fillTypeIndex
    DispatchSmokeTest.collectionGrainStorage     = grainStorage
    DispatchSmokeTest.collectionGrainPlaceable   = grainPlaceable
    DispatchSmokeTest.collectionTotalLitres      = 0
    DispatchSmokeTest.collectionTotalPaid        = 0
    DispatchSmokeTest.tripNumber                 = 0
    DispatchSmokeTest.dispatchCount = DispatchSmokeTest.dispatchCount + 1

    logf("[BOOK] collection #%d START: fillType='%s' siloLevel=%.0fL silo='%s' buyer='%s'",
        DispatchSmokeTest.dispatchCount, ftName, fillLevel,
        tostring(loadingStation.getName and loadingStation:getName() or "?"),
        tostring(buyer.getName and buyer:getName() or "?"))

    -- Match three markers up front: silo (proximity), buyer (proximity to
    -- best buyer), spawn (player-chosen merchant arrival). If any fails
    -- we abort BEFORE spawning — matchADMarkers has toasted the player.
    if not DispatchSmokeTest:matchADMarkers(merchantId) then
        DispatchSmokeTest:endCollection("AutoDrive marker match failed")
        return false, "Could not match AutoDrive markers — see log"
    end

    -- v0.6 (restored): one-way trip. Spawn at the player's merchant
    -- arrival marker, drive to the silo (load), drive to the buyer
    -- (sale + despawn). Heading on spawn faces the silo so the truck
    -- noses out the right way.
    -- HISTORY: v0.5.99.46 used a return-to-spawn workaround — spawn
    -- and despawn were both the merchant marker, buyer was purely
    -- financial. Future cleanup pass can drop this HISTORY block once
    -- the restored flow has soaked.
    local sp = DispatchSmokeTest.adSpawnMarkerPos
    local sm = DispatchSmokeTest.adSiloMarkerPos
    if sp == nil then
        DispatchSmokeTest:endCollection("merchant marker has no position")
        return false, "The merchant arrival marker has no position"
    end
    local dirX, dirZ = 0, 1
    if sm ~= nil then
        local vx, vz = sm.x - sp.x, sm.z - sp.z
        local len = math.sqrt(vx * vx + vz * vz)
        if len > 0.01 then dirX, dirZ = vx / len, vz / len end
    end
    DispatchSmokeTest.collectionSpawn = { x = sp.x, z = sp.z, dirX = dirX, dirZ = dirZ }
    logf("[BOOK] spawn = merchant marker (%.1f, %.1f) heading=(%.2f, %.2f); despawn at buyer marker",
        sp.x, sp.z, dirX, dirZ)

    DispatchSmokeTest:startNextTrip()
    return true, string.format("Merchant dispatched to collect %s", ftName)
end

-- v0.5.99.30: F9 sets the merchant-truck PICKUP LOCATION — it captures
-- the player's current world position + facing and stores it (per farm,
-- persisted) via GrainCollection. The truck then spawns/despawns there.
-- (F9 and F10 previously both started a collection — F9 was redundant.)
function DispatchSmokeTest:onDispatchInput(actionName, inputValue)
    if g_currentMission == nil then return end
    local node = (g_localPlayer ~= nil and g_localPlayer.getCurrentRootNode)
                  and g_localPlayer:getCurrentRootNode() or nil
    if node == nil then
        logf("[pickup] F9: cannot resolve player position")
        gcToast("GrainCollection: cannot set pickup — no player position", "critical")
        return
    end
    local okT, x, _, z = pcall(getWorldTranslation, node)
    if not okT then
        logf("[pickup] F9: getWorldTranslation failed")
        return
    end

    -- v0.5.99.39: the capsule root node (getCurrentRootNode) is a
    -- non-rotating CCT — getWorldRotation on it is always 0. The
    -- player's real facing is Player:getMovementYaw() (the character-
    -- body heading vanilla itself exposes, e.g. for the water-splash
    -- obstacle rotY). Read that; log every plausible source so the
    -- correct one is verifiable in-game.
    local player = g_localPlayer
    local ry = nil
    if player ~= nil and player.getMovementYaw ~= nil then
        local okM, yaw = pcall(player.getMovementYaw, player)
        if okM and yaw ~= nil then ry = yaw end
    end

    do
        local capOk, _, capRy = pcall(getWorldRotation, node)
        logf("[pickup-debug] capsule rootNode getWorldRotation Y = %s",
            capOk and string.format("%.3f", capRy or 0) or "err")
        logf("[pickup-debug] g_localPlayer:getMovementYaw() = %s",
            (ry ~= nil) and string.format("%.3f", ry) or "nil/unavailable")
        if player ~= nil and player.getMapPositionAndLookYaw ~= nil then
            local okL, _, _, lookYaw = pcall(player.getMapPositionAndLookYaw, player)
            logf("[pickup-debug] g_localPlayer:getMapPositionAndLookYaw() lookYaw = %s",
                okL and string.format("%.3f", lookYaw or 0) or "err")
        end
        local gc  = player ~= nil and player.graphicsComponent or nil
        local grn = gc ~= nil and gc.graphicsRootNode or nil
        if grn ~= nil then
            local okG, _, gRy = pcall(getWorldRotation, grn)
            logf("[pickup-debug] graphicsComponent.graphicsRootNode getWorldRotation Y = %s",
                okG and string.format("%.3f", gRy or 0) or "err")
        else
            logf("[pickup-debug] graphicsComponent.graphicsRootNode not available")
        end
    end

    -- Fallback to the camera look yaw if getMovementYaw was unavailable.
    if ry == nil and player ~= nil and player.getMapPositionAndLookYaw ~= nil then
        local okL, _, _, lookYaw = pcall(player.getMapPositionAndLookYaw, player)
        if okL and lookYaw ~= nil then ry = lookYaw end
    end
    ry = ry or 0

    -- Facing: world forward is (sin(ry), cos(ry)).
    local dirX, dirZ = math.sin(ry), math.cos(ry)
    local farmId = g_currentMission:getFarmId()

    if GrainCollection ~= nil and GrainCollection.setPickupLocation ~= nil then
        GrainCollection:setPickupLocation(farmId, x, z, dirX, dirZ)
        logf("[pickup] saved at (%.1f, %.1f) facingYaw=%.3f rad forward=(%.2f, %.2f) farm=%s",
            x, z, ry, dirX, dirZ, tostring(farmId))
        gcToast(string.format(
            "GrainCollection: pickup location set at (%.0f, %.0f) — press F10 to dispatch", x, z), "ok")
    else
        logf("[pickup] F9: GrainCollection.setPickupLocation unavailable")
        gcToast("GrainCollection: pickup save unavailable", "critical")
    end
end

function DispatchSmokeTest:onDispatchOffsetInput(actionName, inputValue)
    DispatchSmokeTest:startCollection("F10")
end

-- =============================================================
-- Step 1: spawn the truck (continues in onSpawned callback)
-- =============================================================

-- v0.6: resolve the FH16 + Krampe SKS 30/1050 bundle store item that
-- modDesc registered (vehicles/fh16KrampeBundle.xml). Tries a direct
-- filename lookup, then falls back to scanning every store item for one
-- whose xmlFilename ends with our bundle file or whose name matches —
-- robust against however FS25 keys mod store items.
function DispatchSmokeTest:resolveBundleStoreItem()
    if g_storeManager == nil then return nil end
    local suffix = DispatchSmokeTest.BUNDLE_XML_SUFFIX

    if type(g_storeManager.getItemByXMLFilename) == "function" then
        for _, name in ipairs({ suffix, "vehicles/" .. suffix }) do
            local ok, item = pcall(g_storeManager.getItemByXMLFilename, g_storeManager, name)
            if ok and item ~= nil then return item end
        end
    end

    local items = nil
    if type(g_storeManager.getItems) == "function" then
        local ok, r = pcall(g_storeManager.getItems, g_storeManager)
        if ok then items = r end
    end
    items = items or g_storeManager.items
    if type(items) == "table" then
        for _, item in pairs(items) do
            if type(item) == "table" then
                local fn = item.xmlFilename
                if type(fn) == "string"
                        and string.find(fn:lower(), suffix:lower(), 1, true) ~= nil then
                    return item
                end
                if item.name == DispatchSmokeTest.BUNDLE_NAME then
                    return item
                end
            end
        end
    end
    return nil
end

function DispatchSmokeTest:beginSpawn(overrideX, overrideZ, headingDirX, headingDirZ)
    if not g_currentMission:getIsServer() then
        logf("ABORT: not server — AISystem:startJob requires isServer (line 541 of AISystem.lua)")
        return
    end

    local spawnX, spawnZ
    if overrideX ~= nil and overrideZ ~= nil then
        spawnX, spawnZ = overrideX, overrideZ
    else
        local playerNode = (g_localPlayer ~= nil and g_localPlayer.getCurrentRootNode)
                            and g_localPlayer:getCurrentRootNode() or nil
        if playerNode == nil then
            logf("ABORT: cannot resolve player root node")
            return
        end
        local px, _, pz = getWorldTranslation(playerNode)
        local _, ry, _  = getWorldRotation(playerNode)
        spawnX = px + math.sin(ry) * 10
        spawnZ = pz + math.cos(ry) * 10
    end
    local farmId = g_currentMission:getFarmId()

    logf("spawning merchant combo: FH16 + Krampe SKS 30/1050 bundle, pos=(%.1f, terrain, %.1f) farmId=%s",
        spawnX, spawnZ, tostring(farmId))

    -- v0.6: spawn the FH16+Krampe bundle. setStoreItem sees the bundle's
    -- <bundleElements>/<attacherInfo>, so one load() spawns both vehicles
    -- already attached (see v0.6_FH16_KRAMPE_SWAP.md).
    local data = VehicleLoadingData.new()
    local storeItem = DispatchSmokeTest:resolveBundleStoreItem()
    if storeItem == nil then
        logf("ABORT: FH16+Krampe bundle store item not found — is vehicles/%s registered in modDesc <storeItems>?",
            DispatchSmokeTest.BUNDLE_XML_SUFFIX)
        gcToast("Merchant vehicle bundle missing — cannot dispatch", "critical")
        return
    end
    data:setStoreItem(storeItem)
    if not data.isValid then
        logf("ABORT: VehicleLoadingData.isValid=false for the FH16+Krampe bundle '%s'",
            tostring(storeItem.name))
        return
    end
    logf("[trip %d] bundle resolved: '%s' (%d element(s))",
        DispatchSmokeTest.tripNumber, tostring(storeItem.name),
        data.vehicles and #data.vehicles or 0)

    -- v0.6: sample actual terrain height at the spawn XZ rather than
    -- relying on the marker's stored Y. AutoDrive waypoints record Y at
    -- wheel/chassis height which can sit several metres off the ground,
    -- causing a visible drop on spawn. Pcall-guarded; on failure fall
    -- back to the marker Y (if known), otherwise nil for engine default.
    local markerY
    if DispatchSmokeTest.adSpawnMarkerPos ~= nil then
        markerY = DispatchSmokeTest.adSpawnMarkerPos.y
    end
    local terrainY
    if g_terrainNode ~= nil then
        local okT, ty = pcall(getTerrainHeightAtWorldPos, g_terrainNode, spawnX, 0, spawnZ)
        if okT and type(ty) == "number" then terrainY = ty end
    end
    local spawnY
    if terrainY ~= nil then
        spawnY = terrainY + 0.1   -- small lift so the chassis doesn't clip
    elseif markerY ~= nil then
        logf("[BOOK] WARN terrain sample failed at (%.1f, %.1f) — falling back to marker Y", spawnX, spawnZ)
        spawnY = markerY
    else
        logf("[BOOK] WARN terrain sample failed at (%.1f, %.1f) and no marker Y — using engine default", spawnX, spawnZ)
    end
    logf("[BOOK] spawn Y: marker=%s terrain=%s using=%s",
        markerY  and string.format("%.2f", markerY)  or "?",
        terrainY and string.format("%.2f", terrainY) or "?",
        spawnY   and string.format("%.2f", spawnY)   or "default")

    data:setPosition(spawnX, spawnY, spawnZ)
    -- v0.5.99.29: face the truck along the heading. yaw rotates around
    -- Y, forward = (sin(ry), cos(ry)), so ry = atan2(dirX, dirZ).
    -- v0.5.99.31: the truck spawned 180° opposite the player's F9
    -- facing (the player capture round-trips ry cleanly, so the flip
    -- is a coordinate-system quirk — player-character forward sign or
    -- the truck model's forward axis). Negate the heading to correct
    -- it. The [pickup] (capture) and [trip] (spawn) log lines record
    -- the raw values either side of the conversion for confirmation.
    if headingDirX ~= nil and headingDirZ ~= nil and data.setRotation ~= nil then
        local hx, hz = -headingDirX, -headingDirZ
        local ry = math.atan2(hx, hz)
        data:setRotation(0, ry, 0)
        logf("[trip %d] spawn at (%.1f, %.1f) heading-in=(%.2f, %.2f) negated=(%.2f, %.2f) yaw=%.3f rad",
            DispatchSmokeTest.tripNumber, spawnX, spawnZ,
            headingDirX, headingDirZ, hx, hz, ry)
    end
    data:setPropertyState(VehiclePropertyState.MISSION)
    data:setOwnerFarmId(farmId)
    data:setIsSaved(false)

    DispatchSmokeTest.dispatchInProgress = true
    data:load(DispatchSmokeTest.onSpawned, DispatchSmokeTest, nil)
end

-- v0.6 step 1: AutoDrive runtime probe. Confirms the spawned truck
-- carries the AutoDrive specialization (vehicle.ad) and dumps the
-- player's marker network plus the API surface the v0.6 AutoDrive
-- rework will build on. Pure diagnostics — starts/alters nothing.
function DispatchSmokeTest:probeAutoDrive(vehicle)
    logf("================ [AD-probe] AutoDrive runtime probe ================")

    -- (1) AutoDrive presence — reuse GrainCollection's existing detection.
    local adAvail = (GrainCollection ~= nil) and GrainCollection.adAvailable
    local AD      = (GrainCollection ~= nil) and GrainCollection.AD or nil
    local ADGraph = (GrainCollection ~= nil) and GrainCollection.ADGraph or nil
    logf("[AD-probe] adAvailable=%s  AD=%s  ADGraph=%s",
        tostring(adAvail), tostring(AD ~= nil), tostring(ADGraph ~= nil))
    if not adAvail or AD == nil then
        logf("[AD-probe] AutoDrive not available — v0.6 AutoDrive driving cannot run. Probe aborted.")
        logf("====================================================================")
        return
    end

    -- (2) AutoDrive version.
    local adVersion = "?"
    if g_modManager ~= nil and g_modManager.getModByName ~= nil then
        local okM, mod = pcall(g_modManager.getModByName, g_modManager, "FS25_AutoDrive")
        if okM and mod ~= nil and mod.version ~= nil then adVersion = tostring(mod.version) end
    end
    logf("[AD-probe] AutoDrive version (modManager) = %s", adVersion)
    if AD.version ~= nil then logf("[AD-probe] AutoDrive.version field = %s", tostring(AD.version)) end

    -- (3) ExternalInterface API surface we depend on.
    local apiFns = { "StartDriving", "StartDrivingWithPathFinder",
        "GetAvailableDestinations", "GetClosestPointToLocation",
        "registerDestinationListener", "unRegisterDestinationListener", "GetPath" }
    for _, fn in ipairs(apiFns) do
        logf("[AD-probe] AD.%s = %s", fn, tostring(type(AD[fn]) == "function"))
    end

    -- (4) Mode constants.
    local modeParts = {}
    for _, m in ipairs({ "MODE_DRIVETO", "MODE_PICKUPANDDELIVER", "MODE_DELIVERTO",
            "MODE_LOAD", "MODE_UNLOAD" }) do
        table.insert(modeParts, string.format("%s=%s", m, tostring(AD[m])))
    end
    logf("[AD-probe] modes: %s", table.concat(modeParts, " "))

    -- (5) The spawned truck's AutoDrive specialization.
    local ad = vehicle ~= nil and vehicle.ad or nil
    logf("[AD-probe] truck vehicle.ad = %s", tostring(ad ~= nil))
    if ad ~= nil then
        local sm = ad.stateModule
        logf("[AD-probe] vehicle.ad: stateModule=%s drivePathModule=%s taskModule=%s",
            tostring(sm ~= nil), tostring(ad.drivePathModule ~= nil),
            tostring(ad.taskModule ~= nil))
        if sm ~= nil then
            local smParts = {}
            for _, fn in ipairs({ "isActive", "getCurrentMode", "getMode", "setMode",
                    "getFirstMarkerId", "setFirstMarker", "getName" }) do
                table.insert(smParts, string.format("%s=%s", fn, tostring(type(sm[fn]) == "function")))
            end
            logf("[AD-probe] stateModule methods: %s", table.concat(smParts, " "))
            local okA, active = pcall(sm.isActive, sm)
            logf("[AD-probe] stateModule:isActive() = %s", okA and tostring(active) or "err")
            local okMo, mode = pcall(sm.getMode, sm)
            logf("[AD-probe] stateModule:getMode() = %s", okMo and tostring(mode) or "err")
        end
    else
        logf("[AD-probe] WARNING: spawned truck has NO vehicle.ad — AutoDrive spec")
        logf("[AD-probe] not attached to this vehicle type. v0.6 blocked until resolved.")
    end
    logf("[AD-probe] truck:startAutoDrive=%s  truck:stopAutoDrive=%s",
        tostring(type(vehicle.startAutoDrive) == "function"),
        tostring(type(vehicle.stopAutoDrive) == "function"))

    -- (6) Giants AI-job conflict — startAutoDrive rejects a vehicle that is
    -- already an active AI-job vehicle.
    local aiActive = false
    if g_currentMission ~= nil and g_currentMission.aiSystem ~= nil
            and g_currentMission.aiSystem.activeJobVehicles ~= nil then
        for _, v in pairs(g_currentMission.aiSystem.activeJobVehicles) do
            if v == vehicle then aiActive = true break end
        end
    end
    logf("[AD-probe] truck in aiSystem.activeJobVehicles = %s (must be false to startAutoDrive)",
        tostring(aiActive))

    -- (7) Waypoint graph + player markers.
    local wpCount = "?"
    if ADGraph ~= nil and ADGraph.getWayPointsCount ~= nil then
        local okW, n = pcall(ADGraph.getWayPointsCount, ADGraph)
        if okW then wpCount = tostring(n) end
    end
    logf("[AD-probe] AutoDrive waypoint graph size = %s waypoint(s)", wpCount)

    local markers = {}
    if GrainCollection.listADMarkers ~= nil then
        local okMk, mk = pcall(GrainCollection.listADMarkers, GrainCollection)
        if okMk and mk ~= nil then markers = mk end
    end
    logf("[AD-probe] player map markers: %d", #markers)
    for _, m in ipairs(markers) do
        logf("[AD-probe]   marker id=%s name='%s' pos=(%.1f, %.1f, %.1f)",
            tostring(m.id), tostring(m.name), m.x or 0, m.y or 0, m.z or 0)
    end
    if #markers == 0 then
        logf("[AD-probe] NO markers — player has not set up an AutoDrive network.")
        logf("[AD-probe] v0.6 needs at least one marker near each silo and buyer.")
    end

    logf("====================================================================")
end

function DispatchSmokeTest:onSpawned(vehicles, loadState, args)
    local okState = (VehicleLoadingState ~= nil) and (loadState == VehicleLoadingState.OK)
    if not okState or vehicles == nil or #vehicles == 0 then
        DispatchSmokeTest.dispatchInProgress = false
        logf("ABORT: spawn failed (loadState=%s vehicles=%d)",
            tostring(loadState), vehicles and #vehicles or 0)
        return
    end
    -- v0.6: the FH16+Krampe bundle spawns two vehicles. Identify the
    -- motorized truck (the AutoDrive root) and the grain trailer; the
    -- engine attaches them per the bundle's <attacherInfo>.
    local truck, trailer
    for _, v in ipairs(vehicles) do
        if v ~= nil then
            if v.spec_motorized ~= nil then
                truck = truck or v
            else
                trailer = trailer or v
            end
        end
    end
    local vehicle = truck or vehicles[1]
    DispatchSmokeTest.adTrailer = trailer
    logf("merchant combo spawned: truck=%s trailer=%s (%d vehicle(s))",
        tostring(vehicle and vehicle.typeName),
        tostring(trailer and trailer.typeName), #vehicles)
    if vehicle ~= nil then
        logf("  truck rootNode=%s ownerFarmId=%s vehicle.ad=%s",
            tostring(vehicle.rootNode),
            tostring(vehicle.getOwnerFarmId and vehicle:getOwnerFarmId() or "?"),
            tostring(vehicle.ad ~= nil))
    end
    if trailer ~= nil then
        local attachedTo = (trailer.getAttacherVehicle ~= nil)
            and trailer:getAttacherVehicle() or nil
        logf("  trailer rootNode=%s attachedTo=%s",
            tostring(trailer.rootNode),
            attachedTo ~= nil and tostring(attachedTo.typeName) or "<NOT ATTACHED>")
    else
        logf("  WARNING: bundle spawned no trailer — grain capacity missing")
    end

    -- v0.6 step 1: AutoDrive runtime probe — non-destructive, runs before
    -- the existing AIJob path so the data is captured even if that aborts.
    pcall(DispatchSmokeTest.probeAutoDrive, DispatchSmokeTest, vehicle)

    -- v0.6: AutoDrive is the driving controller. Hand the spawned truck
    -- to the AutoDrive trip executor and skip the legacy AIJob path
    -- entirely (constructJob etc. stay in the file but are not reached).
    if DispatchSmokeTest.USE_AUTODRIVE then
        DispatchSmokeTest.activeVehicle = vehicle
        local okAD, errAD = pcall(DispatchSmokeTest.startAutoDriveTrip,
            DispatchSmokeTest, vehicle)
        if not okAD then
            logf("[AD-trip] startAutoDriveTrip EXCEPTION: %s", tostring(errAD))
            DispatchSmokeTest.dispatchInProgress = false
            pcall(DispatchSmokeTest.finishAutoDriveTrip, DispatchSmokeTest, vehicle)
        end
        return
    end

    -- Inspect AI capability before attempting job construction. Mirrors
    -- AIJobLoadAndDeliver:getIsAvailableForVehicle (line 464-534).
    local checks = {
        ["createAgent"]      = vehicle.createAgent ~= nil,
        ["setAITarget"]      = vehicle.setAITarget ~= nil,
        ["getCanStartAIVehicle"] = vehicle.getCanStartAIVehicle ~= nil
                                  and vehicle:getCanStartAIVehicle(),
        ["getAIFillUnits"]   = vehicle.getAIFillUnits ~= nil
                                and next(vehicle:getAIFillUnits() or {}) ~= nil,
        ["getAIDischargeNodes"] = vehicle.getAIDischargeNodes ~= nil
                                   and next(vehicle:getAIDischargeNodes() or {}) ~= nil,
    }
    for name, ok in pairs(checks) do
        logf("  AI capability: %s = %s", name, tostring(ok))
    end
    if not (checks["createAgent"] and checks["setAITarget"]
            and checks["getCanStartAIVehicle"]
            and checks["getAIFillUnits"]
            and checks["getAIDischargeNodes"]) then
        logf("ABORT: vehicle lacks one or more AI capabilities — cannot run AIJobLoadAndDeliver")
        DispatchSmokeTest.dispatchInProgress = false
        return
    end

    -- v0.5.99.23: instrument the AI driving API on the spawned truck
    -- now, while we hold a direct reference to it (installHooks runs
    -- before activeVehicle is set, which is why the v0.5.99.15 vehicle
    -- AI-load hooks never attached — see log line "no vehicle to wrap").
    pcall(DispatchSmokeTest.wrapVehicleAIDriving, DispatchSmokeTest, vehicle)

    local ok, err = pcall(DispatchSmokeTest.constructJob, DispatchSmokeTest, vehicle)
    if not ok then
        DispatchSmokeTest.dispatchInProgress = false
        logf("constructJob EXCEPTION: %s", tostring(err))
        if printCallstack ~= nil then pcall(printCallstack) end
    end
end

-- =============================================================
-- Step 2: find stations + fillType, build job, validate, start
-- =============================================================

local function worldDistanceTo(obj, x, z)
    if obj == nil or obj.owningPlaceable == nil then
        if obj and obj.position then return math.sqrt((obj.position.x - x)^2 + (obj.position.z - z)^2) end
        return math.huge
    end
    local ox, _, oz = getWorldTranslation(obj.owningPlaceable.rootNode or 0)
    if ox == nil then return math.huge end
    return math.sqrt((ox - x)^2 + (oz - z)^2)
end

-- v0.5.99.33: the mod collects GRAIN only. Allow-list of grain fill
-- type internal names — the produce the Produce Collection menu
-- tracks. (No exact existing list to reuse: the menu's rows come from
-- getOwnedSilos, i.e. "whatever's in a spec_silo placeable that has a
-- sell point" — that already excludes lime stations because they
-- aren't spec_silo, but the smoke test's findLoadingStation iterates
-- ALL loading stations, which is how it grabbed a Lime Station.)
DispatchSmokeTest.GRAIN_FILLTYPES = { "BARLEY", "CANOLA", "OAT", "WHEAT" }

-- Lazily-resolved set of allowed grain fill-type indices (stable per
-- session once the fill-type manager is up).
function DispatchSmokeTest:getGrainFillTypeSet()
    if DispatchSmokeTest._grainSet ~= nil then return DispatchSmokeTest._grainSet end
    local set = {}
    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeIndexByName ~= nil then
        for _, name in ipairs(DispatchSmokeTest.GRAIN_FILLTYPES) do
            local idx = g_fillTypeManager:getFillTypeIndexByName(name)
            if idx ~= nil then set[idx] = name end
        end
    end
    DispatchSmokeTest._grainSet = set
    return set
end

-- v0.5.99.34 diagnostic helper: best-effort display name.
local function gcSafeName(obj)
    if obj == nil then return "?" end
    if obj.getName ~= nil then
        local ok, n = pcall(obj.getName, obj)
        if ok and n and n ~= "" then return tostring(n) end
    end
    if obj.typeName ~= nil then return tostring(obj.typeName) end
    return tostring(obj)
end

-- v0.5.99.34 diagnostic: dump every placeable carrying a silo / storage
-- / loadingStation spec — reveals whether a modded-map silo lives in a
-- registry findLoadingStation does not scan. Placeable enumeration
-- mirrors GrainCollection:getOwnedSilos (getPlaceables, else .placeables).
function DispatchSmokeTest:dumpPlaceableRegistry()
    local placeables = nil
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        if g_currentMission.placeableSystem.getPlaceables ~= nil then
            placeables = g_currentMission.placeableSystem:getPlaceables()
        elseif g_currentMission.placeableSystem.placeables ~= nil then
            placeables = g_currentMission.placeableSystem.placeables
        end
    end
    if type(placeables) ~= "table" then
        logf("[findLoadingStation] placeable registry unavailable")
        return
    end
    local silo, storage, loadStn = {}, {}, {}
    for _, p in ipairs(placeables) do
        if p.spec_silo ~= nil           then table.insert(silo,    gcSafeName(p)) end
        if p.spec_storage ~= nil        then table.insert(storage, gcSafeName(p)) end
        if p.spec_loadingStation ~= nil then table.insert(loadStn, gcSafeName(p)) end
    end
    logf("[findLoadingStation] all spec_silo placeables: %d (%s)",
        #silo, table.concat(silo, ", "))
    logf("[findLoadingStation] all spec_storage placeables: %d (%s)",
        #storage, table.concat(storage, ", "))
    logf("[findLoadingStation] all spec_loadingStation placeables: %d (%s)",
        #loadStn, table.concat(loadStn, ", "))
end

-- v0.5.99.35 diagnostic: format a possibly-fillType-keyed table. Numeric
-- keys are resolved to fill-type names where possible.
local function gcDumpFTTable(t)
    if t == nil then return "<nil>" end
    if type(t) ~= "table" then return "<" .. type(t) .. ">" end
    local parts = {}
    for k, v in pairs(t) do
        local label = tostring(k)
        if type(k) == "number" and g_fillTypeManager ~= nil
                and g_fillTypeManager.getFillTypeByIndex ~= nil then
            local ftd = g_fillTypeManager:getFillTypeByIndex(k)
            if ftd ~= nil and ftd.name ~= nil then
                label = ftd.name .. "(" .. tostring(k) .. ")"
            end
        end
        table.insert(parts, label .. "=" .. tostring(v))
    end
    if #parts == 0 then return "{}" end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- v0.5.99.35 diagnostic: sorted "key:type" list of a table's fields.
local function gcDumpFields(t)
    if type(t) ~= "table" then return "<" .. type(t) .. ">" end
    local parts = {}
    for k, v in pairs(t) do
        table.insert(parts, tostring(k) .. ":" .. type(v))
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

-- v0.5.99.35 diagnostic: deep probe of every spec_silo placeable. The
-- Calmsden farm silos (farmSilo01/02) are spec_silo but report empty
-- via the LoadingStation getAISupportedFillTypes path, while the map's
-- Lime Station (also spec_silo) reports fine. Try every plausible
-- accessor and dump every spec_silo field so we can see where the
-- grain data actually lives. Pure diagnostic — no behaviour change.
function DispatchSmokeTest:probeSiloPlaceables()
    local grainSet = self:getGrainFillTypeSet()
    local placeables = nil
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        if g_currentMission.placeableSystem.getPlaceables ~= nil then
            placeables = g_currentMission.placeableSystem:getPlaceables()
        elseif g_currentMission.placeableSystem.placeables ~= nil then
            placeables = g_currentMission.placeableSystem.placeables
        end
    end
    if type(placeables) ~= "table" then
        logf("[silo-probe] placeable registry unavailable")
        return
    end

    for _, p in ipairs(placeables) do
        local silo = p.spec_silo
        if silo ~= nil then
            logf("[silo-probe] === name='%s' ===", gcSafeName(p))

            -- 1-3: direct spec_silo tables.
            logf("[silo-probe]   1.spec_silo.supportedFillTypes = %s", gcDumpFTTable(silo.supportedFillTypes))
            logf("[silo-probe]   2.spec_silo.fillTypes          = %s", gcDumpFTTable(silo.fillTypes))
            logf("[silo-probe]   3.spec_silo.fillLevels         = %s", gcDumpFTTable(silo.fillLevels))

            -- 4: spec_silo.storages — the access path GrainCollection's
            -- own getOwnedSilos uses successfully.
            if type(silo.storages) == "table" then
                logf("[silo-probe]   4.spec_silo.storages = %d", #silo.storages)
                for i, storage in ipairs(silo.storages) do
                    local gfl, gsf
                    if type(storage.getFillLevels) == "function" then
                        local ok, r = pcall(storage.getFillLevels, storage)
                        if ok then gfl = r end
                    end
                    if type(storage.getSupportedFillTypes) == "function" then
                        local ok, r = pcall(storage.getSupportedFillTypes, storage)
                        if ok then gsf = r end
                    end
                    logf("[silo-probe]     storage[%d]: getFillLevels()=%s .fillLevels=%s getSupportedFillTypes()=%s",
                        i, gcDumpFTTable(gfl), gcDumpFTTable(storage.fillLevels), gcDumpFTTable(gsf))
                    logf("[silo-probe]     storage[%d] fields: %s", i, gcDumpFields(storage))
                end
            else
                logf("[silo-probe]   4.spec_silo.storages = <%s>", type(silo.storages))
            end

            -- 5: placeable:getFillLevel(fillTypeIndex) per grain type.
            if type(p.getFillLevel) == "function" then
                local g5 = {}
                for idx, nm in pairs(grainSet) do
                    local ok, v = pcall(p.getFillLevel, p, idx)
                    table.insert(g5, string.format("%s=%s", nm, ok and tostring(v) or "err"))
                end
                table.sort(g5)
                logf("[silo-probe]   5.placeable:getFillLevel per grain = {%s}", table.concat(g5, ", "))
            else
                logf("[silo-probe]   5.placeable:getFillLevel — method not present")
            end

            -- 6: every field on spec_silo (compare farmSilo vs Lime Station).
            logf("[silo-probe]   6.spec_silo fields = %s", gcDumpFields(silo))

            -- Extras: placeable-level accessors.
            logf("[silo-probe]   p.fillLevels=%s  p:getFillUnitFillLevel present=%s  p:getFillLevels present=%s",
                gcDumpFTTable(p.fillLevels),
                tostring(type(p.getFillUnitFillLevel) == "function"),
                tostring(type(p.getFillLevels) == "function"))
        end
    end
end

-- v0.5.99.37: resolve a LoadingStation object for a silo placeable.
-- AIJobLoadAndDeliver structurally needs one (loadingStationParameter,
-- setValues). Try, in order: the placeable's spec_silo.loadingStation,
-- spec_loadingStation, the global registry (a station whose
-- owningPlaceable is ours), the grain object itself if it already IS a
-- LoadingStation (getOwnedSilos Path 2c entries), and finally a station
-- that draws from the grain storage (covers a storage with no
-- owningPlaceable). Returns nil when no station exists at all — the
-- caller then skips this silo with a logged warning.
function DispatchSmokeTest:resolveLoadingStation(placeable, grainObj)
    if placeable ~= nil then
        if placeable.spec_silo ~= nil and placeable.spec_silo.loadingStation ~= nil then
            return placeable.spec_silo.loadingStation, "spec_silo.loadingStation"
        end
        if placeable.spec_loadingStation ~= nil
                and placeable.spec_loadingStation.loadingStation ~= nil then
            return placeable.spec_loadingStation.loadingStation, "spec_loadingStation.loadingStation"
        end
    end
    if grainObj ~= nil and grainObj.getAITargetPositionAndDirection ~= nil
            and grainObj.removeFillLevel ~= nil then
        return grainObj, "grain object is itself a LoadingStation"
    end
    if g_currentMission.storageSystem ~= nil
            and g_currentMission.storageSystem.getLoadingStations ~= nil then
        for _, st in pairs(g_currentMission.storageSystem:getLoadingStations()) do
            if placeable ~= nil and st.owningPlaceable == placeable then
                return st, "global registry (owningPlaceable match)"
            end
            local srcs = st.sourceStorages
            if grainObj ~= nil and type(srcs) == "table" then
                for _, s in pairs(srcs) do
                    if s == grainObj then
                        return st, "global registry (sourceStorages match)"
                    end
                end
            end
        end
    end
    return nil, "none"
end

-- v0.5.99.37: grain discovery now reuses GrainCollection:getOwnedSilos
-- — the mod's own, proven finder (the F7 Produce Collection menu uses
-- it and correctly shows the Calmsden farmSilo01/02 oat). The old
-- getLoadingStations() + getAISupportedFillTypes() scan returned {}
-- for modded silos whose load triggers carry no aiNode.
-- Returns: loadingStation, fillLevel, fillTypeIndex, grainStorage, placeable.
-- restrictFillTypeIndex (optional): when set, only silos holding that
-- exact fill type are considered — used by the menu BOOK flow, where the
-- player picked a specific grain row. nil => best grain across the farm.
function DispatchSmokeTest:findLoadingStation(farmId, restrictFillTypeIndex)
    local grainSet = self:getGrainFillTypeSet()
    if restrictFillTypeIndex ~= nil then
        logf("[findLoadingStation] restricted to fillType index %s",
            tostring(restrictFillTypeIndex))
    end

    local gsParts = {}
    for idx, nm in pairs(grainSet) do
        table.insert(gsParts, string.format("%s(%s)", nm, tostring(idx)))
    end
    logf("[findLoadingStation] grain allow-set = {%s}", table.concat(gsParts, ", "))

    -- Diagnostics retained for visibility.
    pcall(DispatchSmokeTest.dumpPlaceableRegistry, DispatchSmokeTest)
    pcall(DispatchSmokeTest.probeSiloPlaceables, DispatchSmokeTest)

    if GrainCollection == nil or GrainCollection.getOwnedSilos == nil then
        logf("[findLoadingStation] GrainCollection:getOwnedSilos unavailable — cannot discover grain")
        return nil, 0, nil
    end
    local ok, silos = pcall(GrainCollection.getOwnedSilos, GrainCollection, farmId)
    if not ok or type(silos) ~= "table" then
        logf("[findLoadingStation] getOwnedSilos failed: %s", tostring(silos))
        return nil, 0, nil
    end
    logf("[findLoadingStation] getOwnedSilos returned %d entr(ies)", #silos)

    -- Pick the grain entry with the most stock.
    local bestEntry = nil
    for _, e in ipairs(silos) do
        local fti = e.fillTypeIndex
        local lvl = e.fillLevel or 0
        if fti ~= nil and grainSet[fti] ~= nil and lvl > 0
                and (restrictFillTypeIndex == nil or fti == restrictFillTypeIndex) then
            local ftd = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fti)
            logf("[findLoadingStation] grain entry: placeable='%s' fillType=%s level=%.0fL",
                tostring(e.placeableName), (ftd and ftd.name) or tostring(fti), lvl)
            if bestEntry == nil or lvl > (bestEntry.fillLevel or 0) then
                bestEntry = e
            end
        end
    end
    if bestEntry == nil then
        logf("[findLoadingStation] no grain found via getOwnedSilos")
        return nil, 0, nil
    end

    -- Resolve a LoadingStation for the AIJobLoadAndDeliver scaffolding.
    local station, how = self:resolveLoadingStation(bestEntry.placeable, bestEntry.storage)
    if station == nil then
        logf("[findLoadingStation] grain at '%s' but NO LoadingStation resolvable — skipping (the AI job needs one)",
            tostring(bestEntry.placeableName))
        return nil, 0, nil
    end
    -- The silo placeable's world position is the drive-to target. If
    -- getOwnedSilos found the storage without an owningPlaceable, recover
    -- the placeable from the resolved station.
    local placeable = bestEntry.placeable
    if placeable == nil and station ~= nil then
        placeable = station.owningPlaceable
    end

    local ftd = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(bestEntry.fillTypeIndex)
    logf("[findLoadingStation] picked '%s' fillType=%s stock=%.0fL  loadingStation via %s  placeable=%s",
        tostring(bestEntry.placeableName), (ftd and ftd.name) or tostring(bestEntry.fillTypeIndex),
        bestEntry.fillLevel or 0, tostring(how), tostring(placeable ~= nil))

    return station, bestEntry.fillLevel or 0, bestEntry.fillTypeIndex,
        bestEntry.storage, placeable
end

-- v0.5.99.26: pick a real BUYER for the unload, not the loading silo.
-- The loading silo is itself an UnloadingStation and, being closest,
-- was previously chosen for both ends — grain just round-tripped.
-- Now: exclude the loading station's placeable; prefer a station named
-- "Animal Dealer Grain"; else the closest other accepting station;
-- final fallback (warned) is the loading station itself so the test
-- never crashes.
-- Returns: station, distance, pickLabel ("named" / "closest" / "fallback-same").
function DispatchSmokeTest:findUnloadingStation(fillTypeIndex, farmId, refX, refZ, loadingStation)
    if g_currentMission.storageSystem == nil
            or g_currentMission.storageSystem.getUnloadingStations == nil then
        return nil
    end
    local PREFER_NAME = "animal dealer grain"
    local loadingPlaceable = loadingStation and loadingStation.owningPlaceable or nil

    local others, sameAsLoading = {}, {}
    for _, st in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
        local accessible = g_currentMission.accessHandler == nil
            or g_currentMission.accessHandler:canPlayerAccess(st)
        if accessible and st.isa ~= nil and st:isa(UnloadingStation)
                and st.getAISupportedFillTypes ~= nil then
            local supported = st:getAISupportedFillTypes() or {}
            if supported[fillTypeIndex] then
                local isSame = (st == loadingStation)
                    or (loadingPlaceable ~= nil and st.owningPlaceable == loadingPlaceable)
                local entry = { st = st, dist = worldDistanceTo(st, refX, refZ) }
                table.insert(isSame and sameAsLoading or others, entry)
            end
        end
    end

    -- Preferred: a different-placeable station whose name matches.
    for _, e in ipairs(others) do
        local nm = (e.st.getName and e.st:getName()) or ""
        if string.find(string.lower(nm), PREFER_NAME, 1, true) then
            return e.st, e.dist, "named"
        end
    end
    -- Else: the closest different-placeable accepting station.
    local best, bestDist = nil, math.huge
    for _, e in ipairs(others) do
        if e.dist < bestDist then best, bestDist = e.st, e.dist end
    end
    if best ~= nil then return best, bestDist, "closest" end
    -- Final fallback: the loading station itself (caller logs a warning).
    local fb, fbDist = nil, math.huge
    for _, e in ipairs(sameAsLoading) do
        if e.dist < fbDist then fb, fbDist = e.st, e.dist end
    end
    if fb ~= nil then return fb, fbDist, "fallback-same" end
    return nil
end

-- v0.5.99.27: end the collection — log totals, reset state to idle.
function DispatchSmokeTest:endCollection(reason)
    logf("[collection] COMPLETE (%s): %d trip(s), total %.0fL collected, total £%.2f paid",
        tostring(reason), DispatchSmokeTest.tripNumber,
        DispatchSmokeTest.collectionTotalLitres, DispatchSmokeTest.collectionTotalPaid)
    DispatchSmokeTest.tripState                  = "idle"
    DispatchSmokeTest.betweenTripsTimer          = nil
    DispatchSmokeTest.collectionLoadingStation   = nil
    DispatchSmokeTest.collectionUnloadingStation = nil
    DispatchSmokeTest.collectionFillType         = nil
    DispatchSmokeTest.collectionSpawn            = nil
    DispatchSmokeTest.collectionGrainStorage     = nil
    DispatchSmokeTest.collectionGrainPlaceable   = nil
    DispatchSmokeTest.needsTargetEnforcement     = false
    DispatchSmokeTest.enforceLoadTarget          = nil
    DispatchSmokeTest.enforceUnloadTarget        = nil
    DispatchSmokeTest.adLeg                      = nil
    DispatchSmokeTest.adLegTruck                 = nil
    DispatchSmokeTest.adTrailer                  = nil
    DispatchSmokeTest.adSiloMarkerId             = nil
    DispatchSmokeTest.adBuyerMarkerId            = nil
    DispatchSmokeTest.adSpawnMarkerId            = nil
    DispatchSmokeTest.adSiloMarkerPos            = nil
    DispatchSmokeTest.adBuyerMarkerPos           = nil
    DispatchSmokeTest.adSpawnMarkerPos           = nil
end

-- v0.5.99.27: dispatch the next trip — or finish if the silo is empty
-- / MAX_TRIPS reached. Spawns a fresh truck at SPAWN_POINT.
function DispatchSmokeTest:startNextTrip()
    local station  = DispatchSmokeTest.collectionLoadingStation
    local fillType = DispatchSmokeTest.collectionFillType
    local farmId   = g_currentMission and g_currentMission:getFarmId()
    if station == nil or fillType == nil then
        DispatchSmokeTest:endCollection("no locked target")
        return
    end
    local siloLevel = (station.getFillLevel and station:getFillLevel(fillType, farmId)) or 0
    if siloLevel <= 0.5 then
        DispatchSmokeTest:endCollection("silo empty")
        return
    end
    if DispatchSmokeTest.tripNumber >= DispatchSmokeTest.MAX_TRIPS then
        DispatchSmokeTest:endCollection("MAX_TRIPS reached")
        return
    end
    local sp = DispatchSmokeTest.collectionSpawn
    if sp == nil then
        DispatchSmokeTest:endCollection("no derived spawn point")
        return
    end
    DispatchSmokeTest.tripNumber       = DispatchSmokeTest.tripNumber + 1
    DispatchSmokeTest.tripState        = "active"
    DispatchSmokeTest.tripSaleDone     = false
    DispatchSmokeTest.tripLoadedLitres = 0
    logf("[trip %d] dispatching — siloLevel now %.0fL, spawning truck at (%.1f, %.1f)",
        DispatchSmokeTest.tripNumber, siloLevel, sp.x, sp.z)

    local ok, err = pcall(DispatchSmokeTest.beginSpawn, DispatchSmokeTest,
        sp.x, sp.z, sp.dirX, sp.dirZ)
    if not ok then
        DispatchSmokeTest.dispatchInProgress = false
        logf("[trip %d] beginSpawn EXCEPTION: %s", DispatchSmokeTest.tripNumber, tostring(err))
        DispatchSmokeTest:endCollection("spawn failed")
    end
end

-- v0.5.99.27: despawn the truck once it has returned to DESPAWN_POINT.
function DispatchSmokeTest:despawnTruck(v)
    -- v0.6: the merchant vehicle is a combo — delete the trailer too.
    -- Delete the implement before the root; Vehicle:delete detaches it.
    local trailer = DispatchSmokeTest.adTrailer
    if trailer ~= nil and trailer ~= v and type(trailer.delete) == "function" then
        local ok, err = pcall(trailer.delete, trailer)
        if ok then logf("[trip %d] trailer despawned", DispatchSmokeTest.tripNumber)
        else logf("[trip %d] trailer delete failed: %s", DispatchSmokeTest.tripNumber, tostring(err)) end
    end
    DispatchSmokeTest.adTrailer = nil

    if v == nil then
        logf("[trip %d] despawnTruck: no vehicle", DispatchSmokeTest.tripNumber)
        return
    end
    if type(v.delete) == "function" then
        local ok, err = pcall(v.delete, v)
        if ok then logf("[trip %d] truck despawned", DispatchSmokeTest.tripNumber)
        else logf("[trip %d] truck delete failed: %s", DispatchSmokeTest.tripNumber, tostring(err)) end
    else
        logf("[trip %d] truck has no :delete() — cannot despawn", DispatchSmokeTest.tripNumber)
    end
end

-- Price per litre for a fill type. Prefers the buyer's effective price
-- (the API GrainCollection.lua's own getSellPointsForFillType uses),
-- then the fill type's base price, then a configured fallback.
local function gcGetPricePerLitre(station, fillType)
    if station ~= nil and station.getEffectiveFillTypePrice ~= nil then
        local ok, p = pcall(station.getEffectiveFillTypePrice, station, fillType)
        if ok and p and p > 0 then return p, "buyer" end
    end
    local ftDesc = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillType)
    if ftDesc and ftDesc.pricePerLiter and ftDesc.pricePerLiter > 0 then
        return ftDesc.pricePerLiter, "fillType.pricePerLiter"
    end
    return DispatchSmokeTest.PRICE_PER_LITRE_FALLBACK, "fallback"
end

-- v0.5.99.27: the "sale". The truck has reached DESPAWN_POINT carrying
-- the grain doDirectLoad transferred into it. We do not physically
-- unload — the grain is sold directly: money is credited, the truck
-- (and its grain) despawns. Per-trip, immediate.
function DispatchSmokeTest:doDirectSale(job)
    local fillType = DispatchSmokeTest.collectionFillType
        or (job.fillTypeParameter and job.fillTypeParameter:getFillTypeIndex())
    local farmId   = g_currentMission and g_currentMission:getFarmId()
    local buyer    = DispatchSmokeTest.collectionUnloadingStation

    -- v0.5.99.28: sell exactly what doDirectLoad pulled from the silo
    -- this trip. The previous approach summed truck fillUnit levels,
    -- which double-counted — the Lizard MultiPurpose exposes one
    -- physical cargo hold under multiple fillUnit indices, each
    -- reporting the full level (2000L hold -> 4000L sum -> 2x money).
    local litres = DispatchSmokeTest.tripLoadedLitres or 0

    local price, priceSrc = gcGetPricePerLitre(buyer, fillType)
    local payment   = litres * price
    local ftDesc    = g_fillTypeManager and g_fillTypeManager:getFillTypeByIndex(fillType)
    local ftName    = (ftDesc and ftDesc.title) or tostring(fillType)
    local buyerName = (buyer and buyer.getName and buyer:getName()) or "?"

    if payment > 0 and g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
        local moneyType = (MoneyType and (MoneyType.SOLD_PRODUCTS or MoneyType.OTHER)) or nil
        pcall(g_currentMission.addMoney, g_currentMission, payment, farmId, moneyType, true, true)
    end
    DispatchSmokeTest.collectionTotalLitres = DispatchSmokeTest.collectionTotalLitres + litres
    DispatchSmokeTest.collectionTotalPaid   = DispatchSmokeTest.collectionTotalPaid + payment
    DispatchSmokeTest.tripSaleDone = true
    logf("[direct-sale] trip %d: sold %.0fL of %s to '%s' for £%.2f (price=%.3f/L src=%s)",
        DispatchSmokeTest.tripNumber, litres, ftName, buyerName, payment, price, priceSrc)
end

-- =============================================================
-- v0.6 AUTODRIVE DRIVING PATH
-- =============================================================
-- AutoDrive replaces AIJobLoadAndDeliver as the driving controller.
-- The truck spawns at the F9 pickup point; AutoDrive paths it to a
-- map marker near the silo (direct-load fires on arrival), then to a
-- marker near the buyer (direct-sale fires on arrival), then the
-- truck despawns. Multi-trip reuses the existing startNextTrip /
-- between-trips machinery. doDirectLoad / doDirectSale are unchanged
-- — they are fed a minimal job-shaped shim instead of a real AIJob.

-- World XZ of a placeable or station. Placeables expose rootNode;
-- stations usually expose it via owningPlaceable (mirrors worldDistanceTo).
function DispatchSmokeTest:objectWorldXZ(obj)
    if obj == nil then return nil, nil end
    local node = obj.rootNode
    if node == nil and obj.owningPlaceable ~= nil then
        node = obj.owningPlaceable.rootNode
    end
    if node == nil then return nil, nil end
    local ok, x, _, z = pcall(getWorldTranslation, node)
    if not ok or x == nil then return nil, nil end
    return x, z
end

function DispatchSmokeTest:objectName(obj)
    if obj == nil then return "?" end
    if obj.getName ~= nil then
        local ok, n = pcall(obj.getName, obj)
        if ok and n and n ~= "" then return n end
    end
    return "?"
end

-- Nearest marker (from GrainCollection:listADMarkers entries) to an XZ.
function DispatchSmokeTest:nearestMarker(markers, x, z)
    local best, bestD = nil, math.huge
    for _, m in ipairs(markers) do
        local d = math.sqrt((m.x - x) ^ 2 + (m.z - z) ^ 2)
        if d < bestD then best, bestD = m, d end
    end
    return best, bestD
end

-- v0.6 (restored): proximity-match the silo + best-buyer + look up the
-- player's merchant-arrival marker by id. Three-marker trip:
--   spawn = adSpawnMarker (player-chosen)  -> truck appears here
--   silo  = adSiloMarker  (proximity, 50m) -> drive leg 1 + direct-load
--   buyer = adBuyerMarker (proximity, 50m) -> drive leg 2 + direct-sale,
--                                              despawn at buyer
-- merchantMarkerId is the player's chosen AD marker id from the picker.
-- When nil (legacy F10 dev path) spawn is supplied separately via
-- collectionSpawn and adSpawnMarker* stay nil.
-- HISTORY: v0.5.99.46 collapsed buyer onto the merchant marker ("return
-- to spawn" workaround) — buyer was purely financial, truck never
-- physically visited it. Restored to physical buyer delivery here.
function DispatchSmokeTest:matchADMarkers(merchantMarkerId)
    DispatchSmokeTest.adSiloMarkerId   = nil
    DispatchSmokeTest.adBuyerMarkerId  = nil
    DispatchSmokeTest.adSpawnMarkerId  = nil
    DispatchSmokeTest.adSiloMarkerPos  = nil
    DispatchSmokeTest.adBuyerMarkerPos = nil
    DispatchSmokeTest.adSpawnMarkerPos = nil

    if GrainCollection == nil or not GrainCollection.adAvailable then
        logf("[AD-match] ABORT: AutoDrive not available")
        gcToast("AutoDrive not available — cannot dispatch", "critical")
        return false
    end

    local markers = {}
    if GrainCollection.listADMarkers ~= nil then
        local ok, mk = pcall(GrainCollection.listADMarkers, GrainCollection)
        if ok and mk ~= nil then markers = mk end
    end
    if #markers == 0 then
        logf("[AD-match] ABORT: no AutoDrive markers on this map")
        gcToast("No AutoDrive markers — draw an AutoDrive network first", "critical")
        return false
    end

    local radius = DispatchSmokeTest.AD_MATCH_RADIUS

    -- Silo marker — nearest AutoDrive marker to the grain silo.
    local siloX, siloZ = self:objectWorldXZ(DispatchSmokeTest.collectionGrainPlaceable)
    if siloX == nil then
        logf("[AD-match] ABORT: silo world position unresolved")
        gcToast("Cannot dispatch — silo position unknown", "critical")
        return false
    end
    local siloName = self:objectName(DispatchSmokeTest.collectionGrainPlaceable)
    local siloM, siloD = self:nearestMarker(markers, siloX, siloZ)
    if siloM == nil or siloD > radius then
        logf("[AD-match] ABORT: no AutoDrive marker within %dm of silo '%s' at (%.1f, %.1f) — nearest %.0fm",
            radius, siloName, siloX, siloZ, siloD or -1)
        gcToast("No AutoDrive marker near the silo — please place one", "critical")
        return false
    end
    logf("[AD-match] silo='%s' marker=%s '%s' distance=%.1fm",
        siloName, tostring(siloM.id), tostring(siloM.name), siloD)

    -- Buyer marker — nearest AutoDrive marker to the best-buyer station.
    local buyerX, buyerZ = self:objectWorldXZ(DispatchSmokeTest.collectionUnloadingStation)
    if buyerX == nil then
        logf("[AD-match] ABORT: buyer world position unresolved")
        gcToast("Cannot dispatch — buyer position unknown", "critical")
        return false
    end
    local buyerName = self:objectName(DispatchSmokeTest.collectionUnloadingStation)
    local buyerM, buyerD = self:nearestMarker(markers, buyerX, buyerZ)
    if buyerM == nil or buyerD > radius then
        logf("[BOOK] aborted: no AutoDrive marker within %dm of %s at (%.1f, %.1f) — nearest %.0fm",
            radius, buyerName, buyerX, buyerZ, buyerD or -1)
        gcToast(string.format(
            "No AutoDrive marker near %s — place one near %s to enable haulier deliveries",
            buyerName, buyerName), "critical")
        return false
    end
    logf("[AD-match] buyer='%s' marker=%s '%s' distance=%.1fm",
        buyerName, tostring(buyerM.id), tostring(buyerM.name), buyerD)

    -- Spawn marker — player's merchant-arrival marker (id lookup, no
    -- proximity match — the player picked it deliberately).
    local spawnM
    if merchantMarkerId ~= nil then
        for _, m in ipairs(markers) do
            if m.id == merchantMarkerId then spawnM = m break end
        end
        if spawnM == nil then
            logf("[AD-match] ABORT: merchant arrival marker id=%s no longer exists",
                tostring(merchantMarkerId))
            gcToast("Merchant arrival marker no longer exists — pick another", "critical")
            return false
        end
        logf("[AD-match] spawn marker (player-set) = %s '%s'",
            tostring(spawnM.id), tostring(spawnM.name))
    end

    DispatchSmokeTest.adSiloMarkerId   = siloM.id
    DispatchSmokeTest.adBuyerMarkerId  = buyerM.id
    DispatchSmokeTest.adSiloMarkerPos  = { x = siloM.x, z = siloM.z }
    DispatchSmokeTest.adBuyerMarkerPos = { x = buyerM.x, z = buyerM.z }
    if spawnM ~= nil then
        DispatchSmokeTest.adSpawnMarkerId  = spawnM.id
        DispatchSmokeTest.adSpawnMarkerPos = { x = spawnM.x, y = spawnM.y, z = spawnM.z }
    end
    return true
end

-- Build a minimal job-shaped table so the unchanged doDirectLoad /
-- doDirectSale can run without a real AIJob. doDirectLoad needs
-- loadingNodeInfos (truck fill units) + fillTypeParameter; doDirectSale
-- only reads collection state, the shim is a harmless fallback there.
function DispatchSmokeTest:buildJobShim(vehicle)
    local infos = {}
    local fillType = DispatchSmokeTest.collectionFillType
    -- v0.6: the grain is held by the trailer (Krampe SKS), not the FH16.
    -- Search the trailer first, then the truck as a fallback (covers the
    -- legacy single-vehicle case). Stop at the first source that yields a
    -- grain-capable fill unit, so the truck's diesel/DEF units are never
    -- picked when a real grain trailer is present.
    local sources = {}
    if DispatchSmokeTest.adTrailer ~= nil then
        table.insert(sources, DispatchSmokeTest.adTrailer)
    end
    if vehicle ~= nil then
        table.insert(sources, vehicle)
    end
    for _, src in ipairs(sources) do
        if src.getFillUnits ~= nil then
            local ok, fillUnits = pcall(src.getFillUnits, src)
            if ok and fillUnits ~= nil then
                for index, fu in ipairs(fillUnits) do
                    if (fu.capacity or 0) > 0 then
                        local supports = fu.supportedFillTypes == nil
                            or fillType == nil
                            or fu.supportedFillTypes[fillType]
                        if supports then
                            table.insert(infos, { vehicle = src, fillUnitIndex = index })
                        end
                    end
                end
            end
        end
        if #infos > 0 then break end
    end
    return {
        loadingNodeInfos = infos,
        fillTypeParameter = {
            getFillTypeIndex = function() return DispatchSmokeTest.collectionFillType end,
        },
        loadingStationParameter = {
            getLoadingStation = function() return DispatchSmokeTest.collectionLoadingStation end,
        },
    }
end

-- Distance from the truck to the current leg's destination marker.
function DispatchSmokeTest:adTruckDistanceToMarker(v, leg)
    if v == nil or v.rootNode == nil then return nil end
    local pos = (leg == "to-silo") and DispatchSmokeTest.adSiloMarkerPos
        or DispatchSmokeTest.adBuyerMarkerPos
    if pos == nil then return nil end
    local ok, tx, _, tz = pcall(getWorldTranslation, v.rootNode)
    if not ok or tx == nil then return nil end
    return math.sqrt((tx - pos.x) ^ 2 + (tz - pos.z) ^ 2)
end

-- Start AutoDrive driving the truck to a marker. Mirrors what the
-- player's "start" does: set DriveTo mode, set the first marker, start
-- the mode (DriveToMode:start calls startAutoDrive itself). Returns
-- true only if AutoDrive actually engaged (stateModule active).
function DispatchSmokeTest:adDriveTo(vehicle, markerId, label)
    local AD = GrainCollection and GrainCollection.AD or nil
    if AD == nil or vehicle == nil or vehicle.ad == nil
            or vehicle.ad.stateModule == nil then
        logf("[AD-drive] ABORT (%s): AD=%s vehicle.ad=%s",
            tostring(label), tostring(AD ~= nil),
            tostring(vehicle ~= nil and vehicle.ad ~= nil))
        return false
    end
    if not vehicle.isServer then
        logf("[AD-drive] ABORT (%s): not server — AutoDrive start is server-only", tostring(label))
        return false
    end
    local sm = vehicle.ad.stateModule

    if AD.MODE_DRIVETO ~= nil and sm.setMode ~= nil then
        pcall(sm.setMode, sm, AD.MODE_DRIVETO)
    end
    if sm.setFirstMarker == nil then
        logf("[AD-drive] ABORT (%s): stateModule has no setFirstMarker", tostring(label))
        return false
    end
    pcall(sm.setFirstMarker, sm, markerId)
    if sm.getFirstMarker == nil or sm:getFirstMarker() == nil then
        logf("[AD-drive] ABORT (%s): marker id=%s did not resolve to a map marker",
            tostring(label), tostring(markerId))
        return false
    end

    local mode = sm.getCurrentMode and sm:getCurrentMode() or nil
    if mode == nil or mode.start == nil then
        logf("[AD-drive] ABORT (%s): no current mode to start", tostring(label))
        return false
    end
    local okS, errS = pcall(mode.start, mode)
    if not okS then
        logf("[AD-drive] ABORT (%s): mode:start threw %s", tostring(label), tostring(errS))
        return false
    end

    local active = sm.isActive and sm:isActive() or false
    logf("[AD-drive] %s: started -> marker=%s, AutoDrive active=%s",
        tostring(label), tostring(markerId), tostring(active))
    return active == true
end

-- Begin an AutoDrive trip with the freshly-spawned truck: drive to the
-- silo marker. Called from onSpawned in place of constructJob.
-- v0.6: set the merchant truck's per-vehicle AutoDrive cornerSpeed so it
-- takes corners at ~50% of AutoDrive's default cornering curve. AutoDrive
-- already detects corners itself — this only scales them. See
-- v0.6_AUTODRIVE_SPEED_CONTROL.md. Internal AD API: feature-detected.
function DispatchSmokeTest:applyHaulierCornerSpeed(truck)
    local AD = GrainCollection and GrainCollection.AD or nil
    if AD == nil or type(AD.setSettingState) ~= "function"
            or AD.settings == nil or AD.settings.cornerSpeed == nil then
        logf("[AD-speed] cornerSpeed setting unavailable — using AutoDrive defaults")
        return
    end
    if truck == nil or truck.ad == nil then
        logf("[AD-speed] no truck.ad — cannot set cornerSpeed")
        return
    end
    local idx = DispatchSmokeTest.AD_CORNER_SPEED_INDEX
    local ok, err = pcall(AD.setSettingState, "cornerSpeed", idx, truck)
    if not ok then
        logf("[AD-speed] setSettingState failed: %s", tostring(err))
        return
    end
    local val = "?"
    if type(AD.getSetting) == "function" then
        local okG, v = pcall(AD.getSetting, "cornerSpeed", truck)
        if okG and v ~= nil then val = tostring(v) end
    end
    logf("[AD-speed] cornerSpeed set to index %d (value %s) on merchant truck", idx, val)
end

function DispatchSmokeTest:startAutoDriveTrip(vehicle)
    DispatchSmokeTest.activeVehicle = vehicle
    DispatchSmokeTest.adLegTruck    = vehicle
    DispatchSmokeTest.adLeg         = nil
    DispatchSmokeTest.adLegPollAcc  = 0

    -- v0.6: corner this truck at 50% (per-vehicle AutoDrive setting).
    DispatchSmokeTest:applyHaulierCornerSpeed(vehicle)

    local siloMarker = DispatchSmokeTest.adSiloMarkerId
    if siloMarker == nil then
        logf("[AD-trip] ABORT: no silo marker matched (matchADMarkers not run?)")
        DispatchSmokeTest.dispatchInProgress = false
        DispatchSmokeTest:finishAutoDriveTrip(vehicle)
        return
    end
    logf("[AD-trip] trip %d: dispatching truck to silo marker %s",
        DispatchSmokeTest.tripNumber, tostring(siloMarker))
    if self:adDriveTo(vehicle, siloMarker, "to-silo") then
        DispatchSmokeTest.adLeg = "to-silo"
    else
        logf("[AD-trip] ABORT: could not start the drive to the silo")
        DispatchSmokeTest.dispatchInProgress = false
        DispatchSmokeTest:finishAutoDriveTrip(vehicle)
    end
end

-- Per-frame: poll the AutoDrive leg. stateModule:isActive() is true
-- while driving and flips false when the route ends. adDriveTo already
-- confirmed it was true at leg start, so the first false = leg done.
function DispatchSmokeTest:updateAutoDrive(dt)
    local leg = DispatchSmokeTest.adLeg
    if leg == nil then return end

    local v = DispatchSmokeTest.adLegTruck
    if v == nil or v.ad == nil or v.ad.stateModule == nil then
        logf("[AD-drive] truck / stateModule lost mid-leg — ending trip")
        DispatchSmokeTest.adLeg = nil
        DispatchSmokeTest:finishAutoDriveTrip(v)
        return
    end
    local sm = v.ad.stateModule
    local active = sm.isActive and sm:isActive() or false

    DispatchSmokeTest.adLegPollAcc = (DispatchSmokeTest.adLegPollAcc or 0) + (dt or 0)
    if DispatchSmokeTest.adLegPollAcc >= 2000 then
        DispatchSmokeTest.adLegPollAcc = 0
        local d = self:adTruckDistanceToMarker(v, leg)
        logf("[AD-drive] leg=%s active=%s distanceToMarker=%s",
            leg, tostring(active), d and string.format("%.1fm", d) or "?")
    end

    if active then return end   -- still driving

    -- Leg finished. Log how it ended.
    local d = self:adTruckDistanceToMarker(v, leg)
    logf("[AD-drive] leg=%s COMPLETE: active=false isStoppingWithError=%s distanceToMarker=%s",
        leg, tostring(v.ad.isStoppingWithError), d and string.format("%.1fm", d) or "?")

    if leg == "to-silo" then
        DispatchSmokeTest.adLeg = nil   -- clear before re-entrant calls
        local shim = self:buildJobShim(v)
        logf("[AD-trip] trip %d: arrived at silo — direct-loading (%d fill unit(s))",
            DispatchSmokeTest.tripNumber, #shim.loadingNodeInfos)
        pcall(DispatchSmokeTest.doDirectLoad, DispatchSmokeTest, shim)

        local buyerMarker = DispatchSmokeTest.adBuyerMarkerId
        if buyerMarker ~= nil and self:adDriveTo(v, buyerMarker, "to-buyer") then
            DispatchSmokeTest.adLeg        = "to-buyer"
            DispatchSmokeTest.adLegPollAcc = 0
        else
            logf("[AD-trip] could not start the drive to the buyer — selling in place")
            pcall(DispatchSmokeTest.doDirectSale, DispatchSmokeTest, self:buildJobShim(v))
            DispatchSmokeTest:finishAutoDriveTrip(v)
        end
    elseif leg == "to-buyer" then
        DispatchSmokeTest.adLeg = nil
        logf("[AD-trip] trip %d: arrived at buyer — direct-selling",
            DispatchSmokeTest.tripNumber)
        pcall(DispatchSmokeTest.doDirectSale, DispatchSmokeTest, self:buildJobShim(v))
        DispatchSmokeTest:finishAutoDriveTrip(v)
    end
end

-- End an AutoDrive trip: stop AutoDrive if still running, despawn the
-- truck, then continue the multi-trip loop or finish the collection.
-- Mirrors the tail of onAIJobStopped.
function DispatchSmokeTest:finishAutoDriveTrip(truck)
    DispatchSmokeTest.adLeg              = nil
    DispatchSmokeTest.adLegTruck         = nil
    DispatchSmokeTest.dispatchInProgress = false

    if truck ~= nil then
        if truck.isServer and truck.stopAutoDrive ~= nil and truck.ad ~= nil
                and truck.ad.stateModule ~= nil and truck.ad.stateModule.isActive ~= nil then
            local okA, busy = pcall(truck.ad.stateModule.isActive, truck.ad.stateModule)
            if okA and busy then
                logf("[AD-trip] AutoDrive still active at trip end — stopping it before despawn")
                pcall(truck.stopAutoDrive, truck)
            end
        end
        DispatchSmokeTest:despawnTruck(truck)
    end

    if DispatchSmokeTest.tripState ~= "active" then return end

    if DispatchSmokeTest.tripSaleDone then
        local station  = DispatchSmokeTest.collectionLoadingStation
        local fillType = DispatchSmokeTest.collectionFillType
        local farmId   = g_currentMission and g_currentMission:getFarmId()
        local siloLevel = (station and station.getFillLevel
            and station:getFillLevel(fillType, farmId)) or 0
        if siloLevel > 0.5 and DispatchSmokeTest.tripNumber < DispatchSmokeTest.MAX_TRIPS then
            DispatchSmokeTest.tripState         = "between-trips"
            DispatchSmokeTest.betweenTripsTimer = DispatchSmokeTest.BETWEEN_TRIPS_DELAY_MS
            logf("[AD-trip] trip %d done; siloLevel=%.0fL remaining; next trip in %.0fs",
                DispatchSmokeTest.tripNumber, siloLevel,
                DispatchSmokeTest.BETWEEN_TRIPS_DELAY_MS / 1000)
        else
            DispatchSmokeTest:endCollection(siloLevel <= 0.5 and "silo empty" or "MAX_TRIPS reached")
        end
    else
        logf("[AD-trip] trip %d FAILED before sale — ending collection",
            DispatchSmokeTest.tripNumber)
        DispatchSmokeTest:endCollection("trip failed")
    end
end

function DispatchSmokeTest:constructJob(vehicle)
    local farmId = g_currentMission:getFarmId()

    -- v0.5.99.27: use the collection target locked in at F9/F10 press.
    local loadingStation   = DispatchSmokeTest.collectionLoadingStation
    local fillTypeIndex    = DispatchSmokeTest.collectionFillType
    local unloadingStation = DispatchSmokeTest.collectionUnloadingStation
    if loadingStation == nil or fillTypeIndex == nil or unloadingStation == nil then
        logf("ABORT: constructJob called with no locked collection target")
        DispatchSmokeTest.dispatchInProgress = false
        return
    end
    local fillLevel = (loadingStation.getFillLevel
        and loadingStation:getFillLevel(fillTypeIndex, farmId)) or 0
    local ft = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    logf("loading station: name=%s fillLevel=%dL fillType=%s (idx=%d) buyer=%s",
        tostring(loadingStation:getName()), math.floor(fillLevel),
        tostring(ft and ft.title or "?"), fillTypeIndex,
        tostring(unloadingStation:getName()))

    -- v0.5.99.38: reset per-job target-enforcement state. Decided below
    -- once setValues has run (driveToLoadingTask unbound => no AI node).
    DispatchSmokeTest.needsTargetEnforcement = false
    DispatchSmokeTest.enforceLoadTarget      = nil
    DispatchSmokeTest.enforceUnloadTarget    = nil

    logf("constructing AIJobLoadAndDeliver")
    local job = AIJobLoadAndDeliver.new(g_currentMission:getIsServer())

    -- applyCurrentState populates valid station lists + selects fill types
    -- per AIJobLoadAndDeliver.lua:217-258. Pass the spawned vehicle.
    local okApply, errApply = pcall(job.applyCurrentState, job,
        vehicle, g_currentMission, farmId, true)
    if not okApply then
        logf("ABORT: applyCurrentState threw: %s", tostring(errApply))
        DispatchSmokeTest.dispatchInProgress = false
        return
    end

    -- Override the auto-selected params with our explicit picks.
    job.vehicleParameter:setVehicle(vehicle)
    job.loadingStationParameter:setLoadingStation(loadingStation)
    job.fillTypeParameter:setFillTypeIndex(fillTypeIndex)
    job.unloadingStationParameter:setUnloadingStation(unloadingStation)
    if job.loopingParameter and job.loopingParameter.setIsLooping then
        job.loopingParameter:setIsLooping(false)
    end

    -- v0.5.99.5: probe what each station returns from
    -- getAITargetPositionAndDirection BEFORE setValues. setValues binds
    -- loadingTask.loadTrigger and dischargeTask.unloadTrigger ONLY if the
    -- station returns a non-nil trigger (AIJobLoadAndDeliver.lua:154-158
    -- and 162-166). A nil trigger here is the smoking gun for "truck
    -- drives to area but doesn't stop."
    if loadingStation.getAITargetPositionAndDirection ~= nil then
        local ok, lx, lz, ldx, ldz, lTrigger = pcall(
            loadingStation.getAITargetPositionAndDirection, loadingStation, fillTypeIndex)
        if ok then
            logf("loadingStation probe: pos=(%.1f, %.1f) dir=(%.2f, %.2f) trigger=%s",
                lx or 0, lz or 0, ldx or 0, ldz or 0, tostring(lTrigger))
            if lTrigger == nil then
                local nTriggers = (loadingStation.loadTriggers and #loadingStation.loadTriggers) or 0
                logf("  WARN: loadingStation returned NO trigger for fillType=%d. Station has %d loadTrigger(s).",
                    fillTypeIndex, nTriggers)
                if loadingStation.loadTriggers then
                    for i, t in ipairs(loadingStation.loadTriggers) do
                        local supportsAI = t.getSupportAILoading and t:getSupportAILoading()
                        logf("    loadTrigger[%d]: supportsAILoading=%s",
                            i, tostring(supportsAI))
                    end
                end
            end
        else
            logf("loadingStation probe FAILED: %s", tostring(lx))
        end
    end
    if unloadingStation.getAITargetPositionAndDirection ~= nil then
        local ok, ux, uz, udx, udz, uTrigger = pcall(
            unloadingStation.getAITargetPositionAndDirection, unloadingStation, fillTypeIndex)
        if ok then
            logf("unloadingStation probe: pos=(%.1f, %.1f) dir=(%.2f, %.2f) trigger=%s",
                ux or 0, uz or 0, udx or 0, udz or 0, tostring(uTrigger))
        else
            logf("unloadingStation probe FAILED: %s", tostring(ux))
        end
    end

    -- setValues binds parameters to tasks (line 73-171 of the job).
    local okSet, errSet = pcall(job.setValues, job)
    if not okSet then
        logf("ABORT: setValues threw: %s", tostring(errSet))
        DispatchSmokeTest.dispatchInProgress = false
        return
    end

    -- v0.5.99.15: the full trigger-rebind (setTargetPosition /
    -- setTargetDirection from the trigger aiNode) stays REMOVED — we
    -- trust setValues' station-derived drive-to position.
    --
    -- v0.5.99.18: but reinstate ONLY the offset-zeroing half. This was
    -- the actual fix from 0.5.99.11; it was wrongly dropped in .14
    -- along with the rest of the rebind. setValues sets
    -- driveTo*.offset = -maxLoadingOffset / -maxDischargeOffset
    -- (AIJobLoadAndDeliver.lua:143, 149) — a backwards offset relative
    -- to the station aiTarget. With a non-zero offset AITaskDriveTo
    -- runs its two-phase OFFSET_POS -> FINAL_POS drive, and the Lizard
    -- truck overshoots the FINAL leg by ~4 m (0.5.99.17 retest
    -- reproduced this). With offset 0, AITaskDriveTo:startDriving takes
    -- the single-phase path: straight to FINAL_POS, one onTargetReached,
    -- truck parks cleanly. Position/direction are untouched — only the
    -- offset is zeroed. One line per task, exactly as 0.5.99.11.
    if job.driveToLoadingTask ~= nil then
        job.driveToLoadingTask:setTargetOffset(0)
    end
    if job.driveToUnloadingTask ~= nil then
        job.driveToUnloadingTask:setTargetOffset(0)
    end

    -- v0.5.99.27: repurpose driveToUnloadingTask as the "drive back off
    -- the farm" leg. We never physically unload at the buyer — the
    -- grain is sold directly (doDirectSale) and the truck despawns. So
    -- point this task at the despawn point instead of the buyer.
    -- v0.5.99.29: despawn point = the derived spawn point (drive back
    -- the way it came).
    -- v0.5.99.32: this also IS the U-turn target. driveToUnloadingTask
    -- targets the pickup point (far away) with heading = collectionSpawn
    -- .dir, which is 180° opposite the spawn heading (beginSpawn derives
    -- the spawn rotation from -collectionSpawn.dir). When the proximity
    -- check force-finishes driveToLoading at the silo, getNextTaskIndex
    -- starts this task and AITaskDriveTo:start issues setAITarget to
    -- this far point with the reversed heading — so the nav agent plans
    -- a forward U-turn, not a long reverse.
    local dp = DispatchSmokeTest.collectionSpawn
    if job.driveToUnloadingTask ~= nil and dp ~= nil then
        job.driveToUnloadingTask:setTargetPosition(dp.x, dp.z)
        job.driveToUnloadingTask:setTargetDirection(dp.dirX, dp.dirZ)
        job.driveToUnloadingTask:setTargetOffset(0)
        -- v0.5.99.38: this target is fully derived by us, so it is a
        -- candidate for per-frame enforcement (gated by needsTargetEnforcement).
        DispatchSmokeTest.enforceUnloadTarget =
            { x = dp.x, z = dp.z, dirX = dp.dirX, dirZ = dp.dirZ }
        logf("  driveToUnloadingTask -> drive-back/U-turn target: pos=(%.1f, %.1f) heading=(%.2f, %.2f)",
            dp.x, dp.z, dp.dirX, dp.dirZ)
    end

    -- v0.5.99.37: bind driveToLoadingTask to the silo placeable's world
    -- position when setValues left it unbound. Modded silos (Calmsden
    -- farmSilo01/02) carry no AI node on their load trigger, so
    -- loadingStation:getAITargetPositionAndDirection returns nil and
    -- setValues never sets driveTo*.x/.z. The direct-transfer flow only
    -- needs the truck to get NEAR the silo — the proximity check
    -- (ARRIVAL_RADIUS) force-finishes this task and doDirectLoad does the
    -- actual grain transfer. Vanilla AI-equipped silos (Hartwell) keep
    -- the setValues binding untouched.
    local gp = DispatchSmokeTest.collectionGrainPlaceable
    if job.driveToLoadingTask ~= nil
            and (job.driveToLoadingTask.x == nil or job.driveToLoadingTask.z == nil)
            and gp ~= nil and gp.rootNode ~= nil then
        local sx, _, sz = getWorldTranslation(gp.rootNode)
        local dx, dz = 0, 1
        local sp = DispatchSmokeTest.collectionSpawn
        if sp ~= nil then
            local vx, vz = sx - sp.x, sz - sp.z
            local len = math.sqrt(vx * vx + vz * vz)
            if len > 0.01 then dx, dz = vx / len, vz / len end
        end
        job.driveToLoadingTask:setTargetPosition(sx, sz)
        job.driveToLoadingTask:setTargetDirection(dx, dz)
        job.driveToLoadingTask:setTargetOffset(0)
        -- v0.5.99.38: setValues left this unbound => the silo has no AI
        -- node. Vanilla's task lifecycle can wipe our derived target
        -- before/during driving, so enforce it per-frame on both legs.
        DispatchSmokeTest.needsTargetEnforcement = true
        DispatchSmokeTest.enforceLoadTarget =
            { x = sx, z = sz, dirX = dx, dirZ = dz }
        logf("[enforce] needsTargetEnforcement=true (silo has no AI node)")
        logf("  driveToLoadingTask -> silo placeable pos=(%.1f, %.1f) dir=(%.2f, %.2f) [no AI node, derived]",
            sx, sz, dx, dz)
    end

    -- v0.5.99.37: if driveToLoadingTask STILL has no target (no AI node
    -- AND no usable placeable node), abort gracefully — running the job
    -- with a nil nav target would crash.
    if job.driveToLoadingTask ~= nil
            and (job.driveToLoadingTask.x == nil or job.driveToLoadingTask.z == nil) then
        logf("ABORT: driveToLoadingTask has no target position (silo has no AI node and no placeable node) — cannot dispatch")
        gcToast("Cannot reach that silo — no drive-to point", "critical")
        DispatchSmokeTest.dispatchInProgress = false
        return
    end

    -- Log final drive-to bindings so the truck destination + offset are
    -- unambiguous in the run log.
    if job.driveToLoadingTask ~= nil then
        logf("  driveToLoadingTask post-setValues (offset zeroed): pos=(%s, %s) dir=(%s, %s) offset=%s",
            tostring(job.driveToLoadingTask.x),
            tostring(job.driveToLoadingTask.z),
            tostring(job.driveToLoadingTask.dirX),
            tostring(job.driveToLoadingTask.dirZ),
            tostring(job.driveToLoadingTask.offset))
    end
    if job.driveToUnloadingTask ~= nil then
        logf("  driveToUnloadingTask post-setValues (offset zeroed): pos=(%s, %s) dir=(%s, %s) offset=%s",
            tostring(job.driveToUnloadingTask.x),
            tostring(job.driveToUnloadingTask.z),
            tostring(job.driveToUnloadingTask.dirX),
            tostring(job.driveToUnloadingTask.dirZ),
            tostring(job.driveToUnloadingTask.offset))
    end

    -- v0.5.99.5/6: post-setValues task dump. Shows what setValues + our
    -- explicit re-bind actually bound. Critical signal: loadingTask.loadTrigger
    -- and dischargeTask.unloadTrigger non-nil, AND drive-to .x/.z non-nil.
    -- v0.5.99.8: switched class resolution to resolveTaskClass (direct
    -- reference comparison) so we always get a real name. Also dump the
    -- loadingTask fields that setValues vs. getNextTaskIndex are
    -- supposed to populate (vehicle / loadVehicle / fillUnitIndex /
    -- offsetZ) and the loadingNodeInfos list — that list drives
    -- getNextTaskIndex's loadingTask:setFillUnit call.
    logf("post-setValues task dump:")
    if job.tasks ~= nil then
        for i, t in ipairs(job.tasks) do
            logf("  task[%d] taskIndex=%s class=%s isRunning=%s isFinished=%s state=%s",
                i, tostring(t.taskIndex),
                DispatchSmokeTest:resolveTaskClass(t),
                tostring(t.isRunning), tostring(t.isFinished),
                tostring(t.state))
        end
    else
        logf("  WARN: job.tasks is nil")
    end
    logf("  loadingTask.loadTrigger      = %s",
        tostring(job.loadingTask and job.loadingTask.loadTrigger))
    logf("  loadingTask.fillType         = %s",
        tostring(job.loadingTask and job.loadingTask.fillType))
    logf("  loadingTask.vehicle          = %s",
        tostring(job.loadingTask and job.loadingTask.vehicle))
    logf("  loadingTask.loadVehicle      = %s (should be nil here; set by getNextTaskIndex)",
        tostring(job.loadingTask and job.loadingTask.loadVehicle))
    logf("  loadingTask.fillUnitIndex    = %s (ditto)",
        tostring(job.loadingTask and job.loadingTask.fillUnitIndex))
    logf("  loadingTask.offsetZ          = %s",
        tostring(job.loadingTask and job.loadingTask.offsetZ))
    logf("  dischargeTask.unloadTrigger  = %s",
        tostring(job.dischargeTask and job.dischargeTask.unloadTrigger))
    if job.loadingNodeInfos ~= nil then
        logf("  loadingNodeInfos: %d entries", #job.loadingNodeInfos)
        for i, info in ipairs(job.loadingNodeInfos) do
            local vname = "nil"
            if info.vehicle ~= nil then
                vname = tostring(info.vehicle.typeName or "?") ..
                        "(rootNode=" .. tostring(info.vehicle.rootNode) .. ")"
            end
            logf("    [%d] vehicle=%s fillUnitIndex=%s offsetZ=%s isDirty=%s",
                i, vname, tostring(info.fillUnitIndex),
                tostring(info.offsetZ), tostring(info.isDirty))
        end
    else
        logf("  WARN: job.loadingNodeInfos is nil")
    end
    if job.dischargeNodeInfos ~= nil then
        logf("  dischargeNodeInfos: %d entries", #job.dischargeNodeInfos)
    end
    -- AITaskDriveTo stores targets as .x / .z / .dirX / .dirZ
    -- (AITaskDriveTo.lua:25-28, 65-79). v0.5.99.5 read .targetPositionX
    -- which doesn't exist — that's why everything showed (nil, nil).
    logf("  driveToLoadingTask target    = (%s, %s) dir=(%s, %s)",
        tostring(job.driveToLoadingTask and job.driveToLoadingTask.x),
        tostring(job.driveToLoadingTask and job.driveToLoadingTask.z),
        tostring(job.driveToLoadingTask and job.driveToLoadingTask.dirX),
        tostring(job.driveToLoadingTask and job.driveToLoadingTask.dirZ))
    logf("  driveToUnloadingTask target  = (%s, %s) dir=(%s, %s)",
        tostring(job.driveToUnloadingTask and job.driveToUnloadingTask.x),
        tostring(job.driveToUnloadingTask and job.driveToUnloadingTask.z),
        tostring(job.driveToUnloadingTask and job.driveToUnloadingTask.dirX),
        tostring(job.driveToUnloadingTask and job.driveToUnloadingTask.dirZ))

    -- v0.5.99.37: validate is now non-fatal. AIJobLoadAndDeliver:validate
    -- calls loadingStation:getIsFillTypeAISupported(fillType), which is
    -- false for modded silos with no AI node on their load trigger (the
    -- Calmsden farm silos) — so vanilla validation REJECTS a perfectly
    -- collectable silo. The direct-transfer flow does not route grain
    -- through the station's AI loading at all (doDirectLoad drains the
    -- Storage object directly), so an AI-support failure here is expected
    -- and harmless. Log the result; only the real structural pieces
    -- (vehicle + both stations, all set explicitly above) must be present.
    local isValid, errorMessage = job:validate(farmId)
    if isValid then
        logf("job constructed: parameters validated OK")
    else
        logf("job validation reported: %s — proceeding anyway (direct-transfer flow does not need station AI support)",
            tostring(errorMessage))
    end

    -- v0.5.99.9: install diagnostic hooks AFTER our setValues + validate
    -- (so our own setup calls aren't logged as suspicious), but BEFORE
    -- startJob (so we catch every call vanilla makes during execution).
    local okHook, errHook = pcall(DispatchSmokeTest.installHooks, DispatchSmokeTest, job)
    if not okHook then
        logf("WARN: installHooks threw: %s — proceeding without hooks",
            tostring(errHook))
    end

    -- Submit to AISystem. Single-player → we are server → direct startJob.
    local okStart, errStart = pcall(function()
        g_currentMission.aiSystem:startJob(job, farmId)
    end)
    if not okStart then
        logf("ABORT: aiSystem:startJob threw: %s", tostring(errStart))
        DispatchSmokeTest.dispatchInProgress = false
        return
    end

    DispatchSmokeTest.activeJob       = job
    DispatchSmokeTest.activeVehicle   = vehicle
    DispatchSmokeTest.lastTaskIndex   = job.currentTaskIndex
    DispatchSmokeTest.lastFillLevel   = -1
    DispatchSmokeTest.pollAccumulator = 0
    DispatchSmokeTest.dispatchInProgress = false
    DispatchSmokeTest.activeJobSeq    = DispatchSmokeTest.nextSeq
    DispatchSmokeTest.nextSeq         = DispatchSmokeTest.nextSeq + 1
    -- v0.5.99.8: reset lifecycle trackers for the new job.
    DispatchSmokeTest.taskLifecycle          = {}
    DispatchSmokeTest.lastTaskIndexSeen      = job.currentTaskIndex
    DispatchSmokeTest.lastLoadingTaskState   = job.loadingTask and job.loadingTask.state
    DispatchSmokeTest.lastLoadingTaskLoadVeh = job.loadingTask and job.loadingTask.loadVehicle
    DispatchSmokeTest.lastLoadingTaskFUI     = job.loadingTask and job.loadingTask.fillUnitIndex
    DispatchSmokeTest.lastLoadingTaskFT      = job.loadingTask and job.loadingTask.fillType
    logf("startJob called: result=OK seq=%d jobId=%s initial taskIndex=%s farmId=%s",
        DispatchSmokeTest.activeJobSeq,
        tostring(job.jobId or "nil"),
        tostring(job.currentTaskIndex), tostring(farmId))
end

-- =============================================================
-- Progress polling + message-bus listeners
-- =============================================================

function DispatchSmokeTest:taskName(idx)
    local j = DispatchSmokeTest.activeJob
    if j == nil or idx == nil then return tostring(idx) end
    if j.driveToLoadingTask   and idx == j.driveToLoadingTask.taskIndex   then return "driveToLoading"  end
    if j.loadingTask          and idx == j.loadingTask.taskIndex          then return "loading"         end
    if j.driveToUnloadingTask and idx == j.driveToUnloadingTask.taskIndex then return "driveToUnloading" end
    if j.dischargeTask        and idx == j.dischargeTask.taskIndex        then return "discharge"       end
    return tostring(idx)
end

-- v0.5.99.38: universal drive-target enforcement. A silo with no AI
-- node leaves driveTo*.x/.z unbound after setValues; constructJob
-- derives a target instead, but vanilla's task lifecycle (reset/start)
-- can wipe driveTo*.x/.z before — or during — driving. Rather than
-- patch every lifecycle hook (whack-a-mole, and map-specific), we
-- re-assert our derived target every frame: restore the task's
-- x/z/dir, and if the truck is already driving and the nav agent has
-- lost the target, re-issue setAITarget. Self-healing within one frame
-- (~16 ms). Gated by needsTargetEnforcement — vanilla-AI silos
-- (Hartwell) keep their setValues binding and are never touched.
-- checkProximityArrival still force-finishes the task at ARRIVAL_RADIUS.
function DispatchSmokeTest:enforceDriveTargets(dt)
    if not DispatchSmokeTest.needsTargetEnforcement then return end
    local j = DispatchSmokeTest.activeJob
    local v = DispatchSmokeTest.activeVehicle
    if j == nil or v == nil then return end

    local taskIdx = j.currentTaskIndex
    local task, tgt, label
    if j.driveToLoadingTask ~= nil and taskIdx == j.driveToLoadingTask.taskIndex then
        task, tgt, label = j.driveToLoadingTask, DispatchSmokeTest.enforceLoadTarget, "driveToLoading"
    elseif j.driveToUnloadingTask ~= nil and taskIdx == j.driveToUnloadingTask.taskIndex then
        task, tgt, label = j.driveToUnloadingTask, DispatchSmokeTest.enforceUnloadTarget, "driveToUnloading"
    else
        return  -- not on a drive-to task
    end
    if task == nil or tgt == nil or task.isFinished then return end

    -- (1) Restore the task fields if vanilla wiped or drifted them.
    -- AITaskDriveTo:startDriving reads task.x/.z/.dir directly, so this
    -- alone fixes the "wiped before driving starts" case.
    local taskWiped = task.x == nil or task.z == nil
        or task.dirX == nil or task.dirZ == nil
        or math.abs(task.x - tgt.x) > 0.5 or math.abs(task.z - tgt.z) > 0.5
    if taskWiped then
        task:setTargetPosition(tgt.x, tgt.z)
        task:setTargetDirection(tgt.dirX, tgt.dirZ)
        task.offset = 0
    end

    -- (2) Once the task is actively driving (past PREPARE), make sure
    -- the nav agent still holds our target; re-issue setAITarget if it
    -- was wiped mid-drive. useManualDriving is left false (omitted) so
    -- the engine keeps pathfinding / planning around obstacles.
    local navReissued = false
    local spec = v.spec_aiDrivable
    local driving = task.isActive
        and AITaskDriveTo ~= nil
        and task.state == AITaskDriveTo.STATE_DRIVE_TO_FINAL_POS
    if driving and spec ~= nil and v.setAITarget ~= nil then
        local navWiped = (not spec.isRunning)
            or spec.targetX == nil or spec.targetZ == nil
            or math.abs(spec.targetX - tgt.x) > 0.5
            or math.abs(spec.targetZ - tgt.z) > 0.5
        if navWiped then
            local y = getTerrainHeightAtWorldPos(g_terrainNode, tgt.x, 0, tgt.z)
            local ok, err = pcall(v.setAITarget, v, task, tgt.x, y, tgt.z, tgt.dirX, 0, tgt.dirZ)
            if ok then navReissued = true
            else logf("[enforce] setAITarget failed: %s", tostring(err)) end
        end
    end

    if taskWiped or navReissued then
        logf("[enforce] re-applying %s target (target was wiped): pos=(%.1f, %.1f) dir=(%.2f, %.2f) taskFields=%s navAgent=%s",
            label, tgt.x, tgt.z, tgt.dirX, tgt.dirZ,
            tostring(taskWiped), tostring(navReissued))
    end
end

-- v0.5.99.31: proximity-based arrival. Runs every frame a job is
-- active. While the current task is a drive-to task (driveToLoading or
-- driveToUnloading), measure the truck's distance to that task's
-- target. Within ARRIVAL_RADIUS, force task.isFinished = true — the
-- next AIJob:update tick then calls getNextTaskIndex, our override
-- fires doDirectLoad / doDirectSale and advances the job. This
-- bypasses AITaskDriveTo's strict target-reached / docking logic,
-- which wedged the truck against the silo.
function DispatchSmokeTest:checkProximityArrival(dt)
    local j = DispatchSmokeTest.activeJob
    local v = DispatchSmokeTest.activeVehicle
    if j == nil or v == nil or v.rootNode == nil then return end
    local taskIdx = j.currentTaskIndex

    local task, label, taskName
    if j.driveToLoadingTask ~= nil and taskIdx == j.driveToLoadingTask.taskIndex then
        task, label, taskName = j.driveToLoadingTask, "silo", "driveToLoading"
    elseif j.driveToUnloadingTask ~= nil and taskIdx == j.driveToUnloadingTask.taskIndex then
        task, label, taskName = j.driveToUnloadingTask, "despawn", "driveToUnloading"
    else
        return  -- not on a drive-to task
    end
    if task.x == nil or task.z == nil then return end

    local okP, tx, _, tz = pcall(getWorldTranslation, v.rootNode)
    if not okP then return end
    local dist = math.sqrt((tx - task.x) ^ 2 + (tz - task.z) ^ 2)
    local radius  = DispatchSmokeTest.ARRIVAL_RADIUS
    local arrived = dist <= radius
    local arrivalEdge = arrived and not task.isFinished

    -- Per-second distance log; always log the arrival edge.
    DispatchSmokeTest.proximityLogAcc = (DispatchSmokeTest.proximityLogAcc or 0) + (dt or 0)
    if arrivalEdge or DispatchSmokeTest.proximityLogAcc >= 1000 then
        if not arrivalEdge then DispatchSmokeTest.proximityLogAcc = 0 end
        logf("[proximity] truck (%.1f, %.1f) -> %s (%.1f, %.1f) distance=%.1fm (radius=%dm, arrived=%s)",
            tx, tz, label, task.x, task.z, dist, radius, tostring(arrived))
    end

    if arrivalEdge then
        logf("[proximity] within %dm of %s — force-finishing %s (skipping tight docking)",
            radius, label, taskName)
        task.isFinished = true
    end
end

function DispatchSmokeTest:pollState()
    local j, v = DispatchSmokeTest.activeJob, DispatchSmokeTest.activeVehicle
    if j == nil or v == nil then return end

    -- Task transitions now logged every frame in update(); skip here.

    local lvl = -1
    if v.getFillUnitFillLevel ~= nil and v.getAIFillUnits then
        local units = v:getAIFillUnits() or {}
        local first = units[1]
        if first then lvl = v:getFillUnitFillLevel(first.fillUnitIndex) or 0 end
    end

    -- v0.5.99.5: always log a heartbeat with task name + vehicle position
    -- so we can see the truck's trajectory even when nothing's changing.
    local x, y, z
    if v.rootNode ~= nil then
        local okT, wx, wy, wz = pcall(getWorldTranslation, v.rootNode)
        if okT then x, y, z = wx, wy, wz end
    end
    local vx = x and string.format("%.1f", x) or "?"
    local vy = y and string.format("%.1f", y) or "?"
    local vz = z and string.format("%.1f", z) or "?"
    logf("  [tick] task=%s pos=(%s, %s, %s) fillLevel=%s",
        DispatchSmokeTest:taskName(j.currentTaskIndex),
        vx, vy, vz, tostring(lvl))

    if lvl ~= DispatchSmokeTest.lastFillLevel then
        DispatchSmokeTest.lastFillLevel = lvl
    end

    -- v0.5.99.7 stuck detector. If task is driveToLoading AND the truck
    -- hasn't moved by more than STUCK_EPSILON_M for STUCK_TICKS polls,
    -- fire the geometry dump ONCE. Reset on task change.
    local isDriveToLoading = (j.driveToLoadingTask ~= nil
                              and j.currentTaskIndex == j.driveToLoadingTask.taskIndex)
    if not isDriveToLoading then
        DispatchSmokeTest.stuckTickCount = 0
        DispatchSmokeTest.stuckDumpFired = false
        DispatchSmokeTest.lastPosX = x
        DispatchSmokeTest.lastPosZ = z
        return
    end
    if x ~= nil and z ~= nil then
        if DispatchSmokeTest.lastPosX ~= nil and DispatchSmokeTest.lastPosZ ~= nil then
            local moved = math.sqrt(
                (x - DispatchSmokeTest.lastPosX)^2 +
                (z - DispatchSmokeTest.lastPosZ)^2)
            if moved < DispatchSmokeTest.STUCK_EPSILON_M then
                DispatchSmokeTest.stuckTickCount = DispatchSmokeTest.stuckTickCount + 1
                if DispatchSmokeTest.stuckTickCount >= DispatchSmokeTest.STUCK_TICKS
                        and not DispatchSmokeTest.stuckDumpFired then
                    logf("STUCK detected on driveToLoading: %d ticks with movement<%.2fm",
                        DispatchSmokeTest.stuckTickCount, DispatchSmokeTest.STUCK_EPSILON_M)
                    pcall(DispatchSmokeTest.dumpGeometry, "stuck-on-driveToLoading")
                    DispatchSmokeTest.stuckDumpFired = true
                end
            else
                DispatchSmokeTest.stuckTickCount = 0
            end
        end
        DispatchSmokeTest.lastPosX = x
        DispatchSmokeTest.lastPosZ = z
    end
end

-- v0.5.99.7 geometric dump. Called at AI_JOB_STOPPED, and once per
-- "stuck" detection on driveToLoading. Answers: where is each fillUnit
-- in world space, where is the trigger, are they overlapping, and what's
-- the truck doing right now?
--
-- v0.5.99.8: was previously a `local function` declared AFTER pollState,
-- so callers that referenced `dumpGeometry` resolved it as a global at
-- call time and got nil. The `pcall(dumpGeometry, ...)` then silently
-- failed for two builds. Now a method on the table — guaranteed
-- resolvable from any call site.
function DispatchSmokeTest.dumpGeometry(reason)
    local v = DispatchSmokeTest.activeVehicle
    local j = DispatchSmokeTest.activeJob
    if v == nil or j == nil then
        logf("dumpGeometry(%s): no active vehicle/job", tostring(reason))
        return
    end
    logf("=== geometry dump (reason=%s) ===", tostring(reason))

    -- Truck world position + heading.
    if v.rootNode ~= nil then
        local okT, x, y, z = pcall(getWorldTranslation, v.rootNode)
        local okR, rx, ry, rz = pcall(getWorldRotation, v.rootNode)
        if okT then
            logf("  truck rootNode pos: (%.2f, %.2f, %.2f)", x, y, z)
        end
        if okR then
            local fx, fz = math.sin(ry), math.cos(ry)
            logf("  truck rootNode rot: (%.3f, %.3f, %.3f) yaw=%.3f rad -> forward=(%.2f, %.2f)",
                rx, ry, rz, ry, fx, fz)
        end
    end
    if v.getLastSpeed ~= nil then
        local okS, spd = pcall(v.getLastSpeed, v)
        if okS then logf("  truck speed: %.2f km/h", spd or 0) end
    end

    -- fillUnits + their exactFillRootNode world positions.
    if v.getAIFillUnits ~= nil then
        local okU, units = pcall(v.getAIFillUnits, v)
        if okU and units ~= nil then
            for _, fu in ipairs(units) do
                local idx = fu.fillUnitIndex
                local fillRootNode = nil
                if v.getFillUnitExactFillRootNode ~= nil then
                    local okN, n = pcall(v.getFillUnitExactFillRootNode, v, idx)
                    if okN then fillRootNode = n end
                end
                local nx, ny, nz = nil, nil, nil
                if fillRootNode ~= nil then
                    local okP, fx, fy, fz = pcall(getWorldTranslation, fillRootNode)
                    if okP then nx, ny, nz = fx, fy, fz end
                end
                local cap = "?"
                if v.getFillUnitCapacity ~= nil then
                    local okC, c = pcall(v.getFillUnitCapacity, v, idx)
                    if okC then cap = tostring(c) end
                end
                local lvl = "?"
                if v.getFillUnitFillLevel ~= nil then
                    local okL, l = pcall(v.getFillUnitFillLevel, v, idx)
                    if okL then lvl = tostring(l) end
                end
                logf("  fillUnit[%d] node=%s pos=(%s, %s, %s) capacity=%s level=%s",
                    idx, tostring(fillRootNode),
                    nx and string.format("%.2f", nx) or "nil",
                    ny and string.format("%.2f", ny) or "nil",
                    nz and string.format("%.2f", nz) or "nil",
                    cap, lvl)
                -- Supported fill types per the fillUnit's own table.
                if v.getFillUnitSupportedFillTypes ~= nil then
                    local okF, sft = pcall(v.getFillUnitSupportedFillTypes, v, idx)
                    if okF and sft ~= nil then
                        local names = {}
                        for ftIdx, ok in pairs(sft) do
                            if ok then
                                local ft = g_fillTypeManager:getFillTypeByIndex(ftIdx)
                                table.insert(names, (ft and ft.name) or tostring(ftIdx))
                            end
                        end
                        logf("    fillUnit[%d] supports: %s", idx, table.concat(names, ", "))
                    end
                end
            end
        end
    end

    -- LoadTrigger: aiNode world position, supported types, currently-inside fillableObjects.
    local lt = j.loadingTask and j.loadingTask.loadTrigger
    if lt ~= nil then
        local nx, ny, nz = nil, nil, nil
        if lt.aiNode ~= nil then
            local okP, x, y, z = pcall(getWorldTranslation, lt.aiNode)
            if okP then nx, ny, nz = x, y, z end
        end
        logf("  loadTrigger aiNode=%s pos=(%s, %s, %s)",
            tostring(lt.aiNode),
            nx and string.format("%.2f", nx) or "nil",
            ny and string.format("%.2f", ny) or "nil",
            nz and string.format("%.2f", nz) or "nil")
        if lt.fillTypes ~= nil then
            local names = {}
            for ftIdx, ok in pairs(lt.fillTypes) do
                if ok then
                    local ft = g_fillTypeManager:getFillTypeByIndex(ftIdx)
                    table.insert(names, (ft and ft.name) or tostring(ftIdx))
                end
            end
            logf("  loadTrigger supports: %s", table.concat(names, ", "))
        end
        if lt.fillableObjects ~= nil then
            local count = 0
            for _, fo in pairs(lt.fillableObjects) do count = count + 1 end
            logf("  loadTrigger.fillableObjects: %d currently inside", count)
            for objectId, fo in pairs(lt.fillableObjects) do
                local isOurTruck = (fo.object == v)
                logf("    objectId=%s fillUnitIndex=%s isOurTruck=%s",
                    tostring(objectId), tostring(fo.fillUnitIndex), tostring(isOurTruck))
            end
        end

        -- Distance from each fillUnit's exactFillRootNode to aiNode.
        if nx ~= nil and v.getAIFillUnits ~= nil then
            local okU, units = pcall(v.getAIFillUnits, v)
            if okU and units ~= nil then
                for _, fu in ipairs(units) do
                    if v.getFillUnitExactFillRootNode ~= nil then
                        local okN, frn = pcall(v.getFillUnitExactFillRootNode, v, fu.fillUnitIndex)
                        if okN and frn ~= nil then
                            local okP, fx, fy, fz = pcall(getWorldTranslation, frn)
                            if okP then
                                local d = math.sqrt((fx - nx)^2 + (fz - nz)^2)
                                logf("  fillUnit[%d] -> loadTrigger.aiNode planar distance: %.2f m",
                                    fu.fillUnitIndex, d)
                            end
                        end
                    end
                end
            end
        end
    end

    -- driveToLoadingTask target (where the AI was told to go).
    local dt = j.driveToLoadingTask
    if dt ~= nil then
        logf("  driveToLoadingTask target=(%s, %s) dir=(%s, %s) offset=%s",
            tostring(dt.x), tostring(dt.z),
            tostring(dt.dirX), tostring(dt.dirZ), tostring(dt.offset))
    end

    logf("=== end geometry dump ===")
end

-- v0.5.99.8 lifecycle summary at AI_JOB_STOPPED. Answers:
--   * Which task index was current when the job stopped?
--   * Did each task ever start? Did each task ever finish?
--   * What was each task's terminal isRunning / isFinished / state?
--   * Did setFillUnit ever run on loadingTask? (loadVehicle, fillUnitIndex)
--   * What's the final isDirty flag on each loadingNodeInfo? (a clean
--     entry means getNextTaskIndex selected it and called setFillUnit;
--     a dirty entry means it was never considered.)
function DispatchSmokeTest.dumpLifecycleSummary(reason)
    local j = DispatchSmokeTest.activeJob
    if j == nil then
        logf("dumpLifecycleSummary(%s): no active job", tostring(reason))
        return
    end
    logf("=== lifecycle summary (reason=%s) ===", tostring(reason))
    logf("  job.currentTaskIndex at stop: %s (%s)",
        tostring(j.currentTaskIndex),
        DispatchSmokeTest:taskName(j.currentTaskIndex))
    logf("  lastTaskIndexSeen (frame-observed): %s (%s)",
        tostring(DispatchSmokeTest.lastTaskIndexSeen),
        DispatchSmokeTest:taskName(DispatchSmokeTest.lastTaskIndexSeen))

    if j.tasks ~= nil then
        for _, t in ipairs(j.tasks) do
            local idx = t.taskIndex
            local rec = DispatchSmokeTest.taskLifecycle[idx]
                or { started = 0, finished = 0, lastState = t.state }
            logf("  task[%s] %s started=%d finished=%d isRunning=%s isFinished=%s state=%s",
                tostring(idx),
                DispatchSmokeTest:resolveTaskClass(t),
                rec.started, rec.finished,
                tostring(t.isRunning), tostring(t.isFinished),
                tostring(t.state))
        end
    end

    if j.loadingTask ~= nil then
        local lt = j.loadingTask
        local ft = lt.fillType and g_fillTypeManager:getFillTypeByIndex(lt.fillType)
        logf("  loadingTask final state:")
        logf("    state           = %s", tostring(lt.state))
        logf("    loadTrigger     = %s", tostring(lt.loadTrigger))
        logf("    fillType        = %s (%s)",
            tostring(lt.fillType), tostring(ft and ft.name or "?"))
        logf("    vehicle         = %s", tostring(lt.vehicle))
        logf("    loadVehicle     = %s", tostring(lt.loadVehicle))
        logf("    fillUnitIndex   = %s", tostring(lt.fillUnitIndex))
        logf("    offsetZ         = %s", tostring(lt.offsetZ))
        logf("    maxSpeed        = %s", tostring(lt.maxSpeed))
    end

    if j.loadingNodeInfos ~= nil then
        logf("  loadingNodeInfos final state: %d entries", #j.loadingNodeInfos)
        for i, info in ipairs(j.loadingNodeInfos) do
            local lvlNow = "?"
            if info.vehicle ~= nil and info.vehicle.getFillUnitFillLevel ~= nil and info.fillUnitIndex ~= nil then
                local okL, lvl = pcall(info.vehicle.getFillUnitFillLevel,
                                       info.vehicle, info.fillUnitIndex)
                if okL then lvlNow = string.format("%.1f", lvl or 0) end
            end
            logf("    [%d] fillUnitIndex=%s offsetZ=%s isDirty=%s fillLevelNow=%s",
                i, tostring(info.fillUnitIndex),
                tostring(info.offsetZ), tostring(info.isDirty), lvlNow)
        end
    end
    logf("=== end lifecycle summary ===")
end

-- Returns the AIMessage subclass name (e.g. "AIMessageSuccessFinishedJob",
-- "AIMessageErrorOutOfFuel"). Falls back to <nil> / <unresolved> if the
-- message is nil or ClassUtil isn't available.
local function describeAIMessage(aiMessage, job)
    if aiMessage == nil then return "<nil>", "" end
    local className = "<unresolved>"
    if ClassUtil ~= nil and ClassUtil.getClassNameByObject ~= nil then
        local ok, name = pcall(ClassUtil.getClassNameByObject, aiMessage)
        if ok and name and name ~= "" then className = name end
    end
    local text = ""
    if aiMessage.getMessage ~= nil then
        local ok, t = pcall(aiMessage.getMessage, aiMessage, job)
        if ok and t and t ~= "" then text = t end
    end
    return className, text
end

function DispatchSmokeTest:onAIJobStarted(job, farmId)
    if job ~= DispatchSmokeTest.activeJob then return end
    logf("AI_JOB_STARTED message: seq=%s jobId=%s farmId=%s",
        tostring(DispatchSmokeTest.activeJobSeq),
        tostring(job.jobId or "nil"), tostring(farmId))
end

function DispatchSmokeTest:onAIJobStopped(job, aiMessage)
    if job ~= DispatchSmokeTest.activeJob then return end
    local msgClass, msgText = describeAIMessage(aiMessage, job)
    logf("AI_JOB_STOPPED message: seq=%s jobId=%s aiMessage=%s text=%q",
        tostring(DispatchSmokeTest.activeJobSeq),
        tostring(job.jobId or "nil"), msgClass, msgText)

    -- v0.5.99.7: geometric dump BEFORE we clear activeVehicle/activeJob,
    -- so dumpGeometry can still read them. v0.5.99.8: also dump the
    -- task-lifecycle summary so we can see what (if anything) ran.
    pcall(DispatchSmokeTest.dumpGeometry, "AI_JOB_STOPPED")
    pcall(DispatchSmokeTest.dumpLifecycleSummary, "AI_JOB_STOPPED")

    -- v0.5.99.27: capture the truck before the clear so we can despawn it.
    local truck = DispatchSmokeTest.activeVehicle

    DispatchSmokeTest.activeJob       = nil
    DispatchSmokeTest.activeVehicle   = nil
    DispatchSmokeTest.activeJobSeq    = nil
    DispatchSmokeTest.lastTaskIndex   = nil
    DispatchSmokeTest.lastFillLevel   = -1
    DispatchSmokeTest.pollAccumulator = 0
    DispatchSmokeTest.lastPosX        = nil
    DispatchSmokeTest.lastPosZ        = nil
    DispatchSmokeTest.stuckTickCount  = 0
    DispatchSmokeTest.stuckDumpFired  = false
    -- v0.5.99.8 lifecycle trackers; cleared so a follow-up F10 dispatch
    -- starts from a clean slate.
    DispatchSmokeTest.taskLifecycle          = {}
    DispatchSmokeTest.lastTaskIndexSeen      = nil
    DispatchSmokeTest.lastLoadingTaskState   = nil
    DispatchSmokeTest.lastLoadingTaskLoadVeh = nil
    DispatchSmokeTest.lastLoadingTaskFUI     = nil
    DispatchSmokeTest.lastLoadingTaskFT      = nil
    DispatchSmokeTest.driveSnapshotAccumulator = 0
    -- v0.5.99.22: clear the drift clamp in case the job stopped before
    -- loadingTask:stop fired, so it doesn't carry into the next dispatch.
    DispatchSmokeTest.loadingClampEnabled = false
    DispatchSmokeTest.loadingClampStartX  = nil
    DispatchSmokeTest.loadingClampStartZ  = nil

    -- v0.5.99.27: multi-trip continuation. The trip's job has stopped —
    -- the truck has returned to DESPAWN_POINT (or the job failed early).
    -- Despawn the truck, then schedule the next trip or finish.
    if DispatchSmokeTest.tripState == "active" then
        DispatchSmokeTest:despawnTruck(truck)
        if DispatchSmokeTest.tripSaleDone then
            local station  = DispatchSmokeTest.collectionLoadingStation
            local fillType = DispatchSmokeTest.collectionFillType
            local farmId   = g_currentMission and g_currentMission:getFarmId()
            local siloLevel = (station and station.getFillLevel
                and station:getFillLevel(fillType, farmId)) or 0
            if siloLevel > 0.5 and DispatchSmokeTest.tripNumber < DispatchSmokeTest.MAX_TRIPS then
                DispatchSmokeTest.tripState         = "between-trips"
                DispatchSmokeTest.betweenTripsTimer = DispatchSmokeTest.BETWEEN_TRIPS_DELAY_MS
                logf("[collection] trip %d done; siloLevel=%.0fL remaining; next trip in %.0fs",
                    DispatchSmokeTest.tripNumber, siloLevel,
                    DispatchSmokeTest.BETWEEN_TRIPS_DELAY_MS / 1000)
            else
                DispatchSmokeTest:endCollection(siloLevel <= 0.5 and "silo empty" or "MAX_TRIPS reached")
            end
        else
            -- Trip ended without reaching the sale (job failed early).
            -- Don't loop on failure — end the collection.
            logf("[collection] trip %d FAILED before sale (job stopped early) — ending collection",
                DispatchSmokeTest.tripNumber)
            DispatchSmokeTest:endCollection("trip failed")
        end
    end
end

addModEventListener(DispatchSmokeTest)
