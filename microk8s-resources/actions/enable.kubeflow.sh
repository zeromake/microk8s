#!/usr/bin/env python3

import json
import os
import random
import string
import subprocess
import sys
import tempfile
import textwrap
import time
from distutils.util import strtobool
from itertools import count


def run(*args, die=True, debug=False):
    # Add wrappers to $PATH
    env = os.environ.copy()
    env["PATH"] += ":%s" % os.environ["SNAP"]

    if debug:
        print("Running `%s`" % " ".join(args))

    result = subprocess.run(
        args,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )

    try:
        result.check_returncode()
    except subprocess.CalledProcessError as err:
        if die:
            print("Kubeflow could not be enabled:")
            if result.stderr:
                print(result.stderr.decode("utf-8"))
            print(err)
            sys.exit(1)
        else:
            raise

    return result.stdout.decode("utf-8")


def get_random_pass():
    return "".join(
        random.choice(string.ascii_uppercase + string.digits) for _ in range(30)
    )


def juju(*args, **kwargs):
    if strtobool(os.environ.get("KUBEFLOW_DEBUG") or "false"):
        return run("microk8s-juju.wrapper", "--debug", *args, debug=True, **kwargs)
    else:
        return run("microk8s-juju.wrapper", *args, **kwargs)


def main():
    password = os.environ.get("KUBEFLOW_AUTH_PASSWORD") or get_random_pass()
    channel = os.environ.get("KUBEFLOW_CHANNEL") or "stable"
    no_proxy = os.environ.get("KUBEFLOW_NO_PROXY") or None
    hostname = os.environ.get("KUBEFLOW_HOSTNAME") or None
    metallb_ip_range = os.environ.get("METALLB_IP_RANGE") or "10.64.140.43-10.64.140.49"

    password_overlay = {
        "applications": {
            "katib-db": {"options": {"root_password": get_random_pass()}},
            "kubeflow-gatekeeper": {"options": {"password": password}},
            "modeldb-db": {"options": {"root_password": get_random_pass()}},
            "pipelines-api": {"options": {"minio-secret-key": "minio123"}},
            "pipelines-db": {"options": {"root_password": get_random_pass()}},
        }
    }

    services = [
        ("dns", None),
        ("storage", None),
        ("dashboard", None),
        ("ingress", None),
        ("rbac", None),
        ("juju", None),
    ]

    if hostname is None:
        services += [("metallb", metallb_ip_range)]

    for service, args in services:
        if args:
            print("Enabling service %s with args %s" % (service, args))
        else:
            print("Enabling service %s..." % service)
        run("microk8s-enable.wrapper", "%s:%s" % (service, args or ""))

    try:
        juju("show-controller", "uk8s", die=False)
    except subprocess.CalledProcessError:
        pass
    else:
        print("Kubeflow has already been enabled.")
        sys.exit(1)

    print("Deploying Kubeflow...")
    if no_proxy is not None:
        juju("bootstrap", "microk8s", "uk8s", "--config=juju-no-proxy=%s" % no_proxy)
        juju("add-model", "kubeflow", "microk8s")
        juju("model-config", "-m", "kubeflow", "juju-no-proxy=%s" % no_proxy)
    else:
        juju("bootstrap", "microk8s", "uk8s")
        juju("add-model", "kubeflow", "microk8s")

    if hostname is None:
        amb_svc = json.dumps(
            {
                "apiVersion": "v1",
                "kind": "Service",
                "metadata": {
                    "name": "ambassador-service",
                    "namespace": "kubeflow",
                    "annotations": {"metallb.universe.tf/address-pool": "default"},
                },
                "spec": {
                    "selector": {"juju-app": "ambassador"},
                    "ports": [{"port": 8000, "targetPort": 80}],
                    "type": "LoadBalancer",
                },
            },
        ).encode("utf-8")
        env = os.environ.copy()
        env["PATH"] += ":%s" % os.environ["SNAP"]

        subprocess.run(
            ["microk8s-kubectl.wrapper", "apply", "-f", "-"],
            input=amb_svc,
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=env,
        ).check_returncode()

        output = run(
            "microk8s-kubectl.wrapper",
            "get",
            "-n",
            "kubeflow",
            "svc/ambassador-service",
            "-ojson",
            die=False,
        )
        pub_ip = json.loads(output)["status"]["loadBalancer"]["ingress"][0]["ip"]
        hostname = "%s.xip.io" % pub_ip
    else:
        ingress = json.dumps(
            {
                "apiVersion": "extensions/v1beta1",
                "kind": "Ingress",
                "metadata": {"name": "ambassador-ingress", "namespace": "kubeflow"},
                "spec": {
                    "rules": [
                        {
                            "host": hostname,
                            "http": {
                                "paths": [
                                    {
                                        "backend": {
                                            "serviceName": "ambassador",
                                            "servicePort": 80,
                                        },
                                        "path": "/",
                                    }
                                ]
                            },
                        }
                    ],
                    "tls": [{"hosts": [hostname], "secretName": "dummy-tls"}],
                },
            }
        ).encode("utf-8")

        env = os.environ.copy()
        env["PATH"] += ":%s" % os.environ["SNAP"]

        subprocess.run(
            ["microk8s-kubectl.wrapper", "apply", "-f", "-"],
            input=ingress,
            stderr=subprocess.PIPE,
            stdout=subprocess.PIPE,
            env=env,
        ).check_returncode()

    with tempfile.NamedTemporaryFile("w+") as f:
        json.dump(password_overlay, f)
        f.flush()

        juju("deploy", "cs:kubeflow", "--channel", channel, "--overlay", f.name)

    print("Kubeflow deployed.")
    print("Waiting for operator pods to become ready.")
    wait_seconds = 15
    for i in count():
        status = json.loads(juju("status", "-m", "uk8s:kubeflow", "--format=json"))
        unready_apps = [
            name
            for name, app in status["applications"].items()
            if "message" in app["application-status"]
        ]
        if unready_apps:
            print(
                "Waited %ss for operator pods to come up, %s remaining."
                % (wait_seconds * i, len(unready_apps))
            )
            time.sleep(wait_seconds)
        else:
            break

    print("Operator pods ready.")
    print("Waiting for service pods to become ready.")
    run(
        "microk8s-kubectl.wrapper",
        "wait",
        "--namespace=kubeflow",
        "--for=condition=Ready",
        "pod",
        "--timeout=-1s",
        "--all",
    )


    print(
        textwrap.dedent(
            """
    Congratulations, Kubeflow is now available.
    The dashboard is available at https://%s/

        Username: admin
        Password: %s

    To see these values again, run:

        microk8s.juju config kubeflow-gatekeeper username
        microk8s.juju config kubeflow-gatekeeper password

    To tear down Kubeflow and associated infrastructure, run:

       microk8s.disable kubeflow
    """
            % (hostname, password)
        )
    )


if __name__ == "__main__":
    main()
