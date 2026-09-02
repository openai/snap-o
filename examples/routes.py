"""Run with: scripts/snapo network intercept examples/routes.py -s DEVICE_SERIAL"""

import asyncio

from snapo import route

tasks = []


@route("GET", "api/profile")
async def profile(call):
    response = await call.upstream()
    response.json["display_name"] = "Space Captain"
    return response


@route("POST", "api/tasks")
async def create_task(call):
    task = {"id": str(len(tasks) + 1), "title": call.request.json["title"], "status": "pending"}
    tasks.append(task)
    return call.json(task, status=201)


@route("GET", "api/tasks")
async def list_tasks(call):
    # Other handlers continue running during this delay.
    await asyncio.sleep(0.5)
    return call.json({"tasks": tasks})
