"""Forward journal frames to one controller with consumer-driven backpressure."""
import asyncio
import base64


async def forward(relay, controller):
    writer, _, ready, acknowledged, drained = controller
    delivered_exit = False
    try:
        while relay.controller is controller:
            ready.clear()
            for end, raw in list(relay.frames):
                if relay.controller is not controller:
                    return
                if relay.stopping:
                    break
                if end > controller[1]:
                    payload = raw.removesuffix(b'\n')
                    try:
                        values = {'line': payload.decode('utf-8')}
                    except UnicodeDecodeError:
                        values = {'line': payload.decode('utf-8', errors='replace'),
                                  'line_base64': base64.b64encode(payload).decode('ascii')}
                    relay.message(writer, 'frame', offset=end, **values)
                    controller[1] = end
                    acknowledged.clear()
                    await asyncio.wait_for(writer.drain(), timeout=1)
                    await acknowledged.wait()
            if relay.exit_status is not None and not delivered_exit and (relay.stopping or controller[1] >= relay.end):
                relay.message(writer, 'exit', status=relay.exit_status)
                await writer.drain()
                delivered_exit = True
                drained.set()
            await ready.wait()
    except (ConnectionError, asyncio.TimeoutError):
        relay.disconnect(writer)
