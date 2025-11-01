import argparse
import logging
import urllib.request
import urllib.error
import base64
import sys
import json
import time
import hashlib
import os


ROBLOX_API_KEY = os.environ["ROBLOX_API_KEY"]
ROBLOX_UNIVERSE_ID = os.environ["ROBLOX_UNIVERSE_ID"]
ROBLOX_PLACE_ID = os.environ["ROBLOX_PLACE_ID"]


def read_file(file_path):
	with open(file_path, "rb") as file:
		return file.read()


def makeRequest(url, headers, body=None):
	data = None
	if body is not None:
		data = body.encode("utf8")
	request = urllib.request.Request(
		url, data=data, headers=headers, method="GET" if body is None else "POST"
	)
	max_attempts = 3
	for i in range(max_attempts):
		try:
			return urllib.request.urlopen(request)
		except Exception as e:
			if "certificate verify failed" in str(e):
				logging.error(
					f"{str(e)} - you may need to install python certificates, see https://stackoverflow.com/questions/27835619/urllib-and-ssl-certificate-verify-failed-error"
				)
				sys.exit(1)
			if i == max_attempts - 1:
				raise e
			else:
				logging.info(f"Retrying error: {str(e)}")
				time.sleep(1)


def readFileExitOnFailure(path, file_description):
	try:
		with open(path, "r") as f:
			return f.read()
	except FileNotFoundError:
		logging.error(f"{file_description.capitalize()} file not found: {path}")
	except IsADirectoryError:
		logging.error(f"Invalid {file_description} file: {path} is a directory")
	except PermissionError:
		logging.error(f"Permission denied to read {file_description} file: {path}")
	sys.exit(1)


def createTask(api_key, script, universe_id, place_id, place_version):
	headers = {"Content-Type": "application/json", "x-api-key": api_key}
	data = {"script": script}
	url = f"https://apis.roblox.com/cloud/v2/universes/{universe_id}/places/{place_id}/"
	if place_version:
		url += f"versions/{place_version}/"
	url += "luau-execution-session-tasks"

	try:
		response = makeRequest(url, headers=headers, body=json.dumps(data))
	except urllib.error.HTTPError as e:
		logging.error(f"Create task request failed, response body:\n{e.fp.read()}")
		sys.exit(1)

	task = json.loads(response.read())
	return task


def pollForTaskCompletion(api_key, path):
	headers = {"x-api-key": api_key}
	url = f"https://apis.roblox.com/cloud/v2/{path}"

	logging.info("Waiting for task to finish...")

	while True:
		try:
			response = makeRequest(url, headers=headers)
		except urllib.error.HTTPError as e:
			logging.error(f"Get task request failed, response body:\n{e.fp.read()}")
			sys.exit(1)

		task = json.loads(response.read())
		if task["state"] != "PROCESSING":
			sys.stderr.write("\n")
			sys.stderr.flush()
			return task
		else:
			sys.stderr.write(".")
			sys.stderr.flush()
			time.sleep(3)


def getTaskLogs(api_key, task_path):
	headers = {"x-api-key": api_key}
	url = f"https://apis.roblox.com/cloud/v2/{task_path}/logs"

	try:
		response = makeRequest(url, headers=headers)
	except urllib.error.HTTPError as e:
		logging.error(f"Get task logs request failed, response body:\n{e.fp.read()}")
		sys.exit(1)

	logs = json.loads(response.read())
	messages = logs["luauExecutionSessionTaskLogs"][0]["messages"]
	return "".join([m + "\n" for m in messages])


def handleLogs(task, log_output_file_path, api_key):
	logs = getTaskLogs(api_key, task["path"])
	if logs:
		if log_output_file_path:
			with open(log_output_file_path, "w") as f:
				f.write(logs)
			logging.info(f"Task logs written to {log_output_file_path}")
		else:
			logging.info(f"Task logs:\n{logs.strip()}")
	else:
		logging.info("The task did not produce any logs")


def handleSuccess(task, output_path):
	output = task["output"]
	if output["results"]:
		if output_path:
			with open(output_path, "w") as f:
				f.write(json.dumps(output["results"]))
			logging.info(f"Task results written to {output_path}")
		else:
			logging.info("Task output:")
			print(json.dumps(output["results"]))
	else:
		logging.info("The task did not return any results")


def handleFailure(task):
	logging.error(f"Task failed, error:\n{json.dumps(task['error'])}")


def upload_place(binary_path, universe_id, place_id, do_publish=False):
	print("Uploading place to Roblox")
	version_type = "Published" if do_publish else "Saved"
	request_headers = {
		"x-api-key": ROBLOX_API_KEY,
		"Content-Type": "application/xml",
		"Accept": "application/json",
	}

	url = f"https://apis.roblox.com/universes/v1/{universe_id}/places/{place_id}/versions?versionType={version_type}"

	buffer = read_file(binary_path)
	req = urllib.request.Request(
		url, data=buffer, headers=request_headers, method="POST"
	)

	with urllib.request.urlopen(req) as response:
		data = json.loads(response.read().decode("utf-8"))
		place_version = data.get("versionNumber")

		return place_version


def run_luau_task(universe_id, place_id, place_version, script_file):
	print("Executing Luau task")
	script_contents = read_file(script_file).decode("utf8")

	task = createTask(
		ROBLOX_API_KEY, script_contents, universe_id, place_id, place_version
	)
	task = pollForTaskCompletion(ROBLOX_API_KEY, task["path"])
	logs = getTaskLogs(ROBLOX_API_KEY, task["path"])

	print(logs)

	if task["state"] == "COMPLETE":
		print("Lua task completed successfully")
		exit(0)
	else:
		print("Luau task failed", file=sys.stderr)
		exit(1)


if __name__ == "__main__":
	universe_id = ROBLOX_UNIVERSE_ID
	place_id = ROBLOX_PLACE_ID
	binary_file = sys.argv[1]
	script_file = sys.argv[2]

	place_version = upload_place(binary_file, universe_id, place_id)

	logging.basicConfig(
		format="[%(asctime)s] [%(name)s] [%(levelname)s]: %(message)s",
		level=logging.INFO,
	)

	script = readFileExitOnFailure(script_file, "script")

	task = createTask(
		ROBLOX_API_KEY, script, ROBLOX_UNIVERSE_ID, ROBLOX_PLACE_ID, place_version
	)
	logging.info(f"Task created, path: {task['path']}")

	task = pollForTaskCompletion(ROBLOX_API_KEY, task["path"])
	logging.info(f"Task is now in {task['state']} state")

	handleLogs(task, None, ROBLOX_API_KEY)
	if task["state"] == "COMPLETE":
		handleSuccess(task, None)
		exit(0)
	else:
		handleFailure(task)
		exit(1)
