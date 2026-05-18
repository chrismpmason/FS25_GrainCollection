--
-- GrainCollectionEvent.lua
-- Minimal MP event so clients see bookings made by other players.
-- Singleplayer ignores this entirely.
--

GrainCollectionEvent = {}
local GrainCollectionEvent_mt = Class(GrainCollectionEvent, Event)

InitEventClass(GrainCollectionEvent, "GrainCollectionEvent")

function GrainCollectionEvent.emptyNew()
    return Event.new(GrainCollectionEvent_mt)
end

function GrainCollectionEvent.new(action, booking)
    local self = GrainCollectionEvent.emptyNew()
    self.action = action      -- "book" or "cancel"
    self.booking = booking
    return self
end

function GrainCollectionEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.action)
    if self.action == "book" then
        streamWriteInt32(streamId, self.booking.id)
        streamWriteInt32(streamId, self.booking.farmId)
        streamWriteInt32(streamId, self.booking.fillTypeIndex)
        streamWriteFloat32(streamId, self.booking.litres)
        streamWriteInt32(streamId, self.booking.dueDay)
        streamWriteFloat32(streamId, self.booking.pricePerLitre)
        streamWriteFloat32(streamId, self.booking.totalNet)
        streamWriteString(streamId, self.booking.unloadingStationName or "")
        streamWriteString(streamId, self.booking.targetMonthLabel or "")
    elseif self.action == "cancel" then
        streamWriteInt32(streamId, self.booking.id)
    end
end

function GrainCollectionEvent:readStream(streamId, connection)
    self.action = streamReadString(streamId)
    if self.action == "book" then
        self.booking = {
            id                   = streamReadInt32(streamId),
            farmId               = streamReadInt32(streamId),
            fillTypeIndex        = streamReadInt32(streamId),
            litres               = streamReadFloat32(streamId),
            dueDay               = streamReadInt32(streamId),
            pricePerLitre        = streamReadFloat32(streamId),
            totalNet             = streamReadFloat32(streamId),
            unloadingStationName = streamReadString(streamId),
            targetMonthLabel     = streamReadString(streamId),
        }
    elseif self.action == "cancel" then
        self.booking = { id = streamReadInt32(streamId) }
    end
    self:run(connection)
end

function GrainCollectionEvent:run(connection)
    if self.action == "book" then
        table.insert(GrainCollection.bookings, self.booking)
        if GrainCollection.nextId <= self.booking.id then
            GrainCollection.nextId = self.booking.id + 1
        end
    elseif self.action == "cancel" then
        for i, b in ipairs(GrainCollection.bookings) do
            if b.id == self.booking.id then
                table.remove(GrainCollection.bookings, i)
                break
            end
        end
    end

    if g_server ~= nil and connection ~= nil then
        g_server:broadcastEvent(self, nil, connection)
    end
end
