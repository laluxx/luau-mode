--!strict

export type CameraState = {
    position: Vector3,
    focus: CFrame,
    enabled: boolean,
}

type Box<T> = { value: T }

local camera: Camera = workspace.CurrentCamera
local origin: Vector3 = Vector3.new(0, 5, 10)

local function selectPosition<T>(value: T, fallback: T): T
    return if value ~= nil then value else fallback
end

local ready = true
if ready then
    camera.CFrame = CFrame.new(selectPosition(origin, origin))
else
    warn(`Missing camera: {camera}`)
end
