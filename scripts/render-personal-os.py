#!/usr/bin/env python3
"""Render a local Kustomize overlay from Terraform outputs and published images."""

import argparse
import json
from pathlib import Path
import re
import subprocess


def image_reference(value):
    if not re.fullmatch(r"[a-zA-Z0-9._:/-]+(?::[a-zA-Z0-9._-]+|@sha256:[a-f0-9]{64})", value):
        raise argparse.ArgumentTypeError("Use a registry/image:version or registry/image@sha256:digest reference")
    if "/" not in value or value.endswith(":latest") or "replace" in value.lower():
        raise argparse.ArgumentTypeError("Use a published registry image with an explicit version, not latest")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-image", required=True, type=image_reference)
    parser.add_argument("--frontend-image", required=True, type=image_reference)
    parser.add_argument("--terraform", default="terraform", help="Terraform executable")
    parser.add_argument("--terraform-output", type=Path, help="Read an existing terraform output -json file")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    if args.terraform_output:
        outputs = json.loads(args.terraform_output.read_text())
    else:
        outputs = json.loads(subprocess.check_output(
            [args.terraform, f"-chdir={root / 'environments/personal-os'}", "output", "-json"],
            text=True,
        ))
    subnet = outputs["load_balancer_subnet_id"]["value"]
    nsg = outputs["load_balancer_nsg_id"]["value"]
    if not subnet.startswith("ocid1.subnet.") or not nsg.startswith("ocid1.networksecuritygroup."):
        parser.error("Terraform outputs must contain a valid load balancer subnet and NSG OCID")

    overlay = {
        "apiVersion": "kustomize.config.k8s.io/v1beta1",
        "kind": "Kustomization",
        "resources": ["../../kubernetes/personal-os"],
        "images": [],
        "patches": [{"patch": json.dumps({
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "name": "personal-os-web",
                "namespace": "personal-os",
                "annotations": {
                    "service.beta.kubernetes.io/oci-load-balancer-subnet1": subnet,
                    "oci.oraclecloud.com/oci-network-security-groups": nsg,
                },
            },
        })}],
    }
    for name, reference in [("personal-os-api", args.api_image), ("personal-os-frontend", args.frontend_image)]:
        if "@sha256:" in reference:
            image, digest = reference.split("@", 1)
            overlay["images"].append({"name": name, "newName": image, "digest": digest})
        else:
            image, tag = reference.rsplit(":", 1)
            overlay["images"].append({"name": name, "newName": image, "newTag": tag})
    destination = root / ".local/personal-os/kustomization.yaml"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(overlay, indent=2) + "\n")
    print(f"Rendered {destination}")
    print("Review: kubectl kustomize .local/personal-os")
    print("Validate against your cluster: kubectl apply --dry-run=server -k .local/personal-os")


if __name__ == "__main__":
    main()
