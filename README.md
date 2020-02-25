# A Jenkins build farm for ESP RTOS SDK projects, running on Google Kubernetes Engine

## Overview

First we'll create a cluster in which we'll run the Jenkins Master and its build agent pods.

This could be done on the GKE web UI, but we're talking about automation, so we'll use Ansible instead.
After the 5th-6th try-fail-teardown-try-again cycle, manual clickery becomes rather boring...

So we'll run the Jenkins Master itself in the cluster as well, using their
[Jenkins Docker image](https://hub.docker.com/r/jenkins/jenkins).

Then, as we intend to run the build agents in the cluster as well, Jenkins will need to know how to spawn them, so we'll
use the [Kubernetes Jenkins plugin](https://github.com/jenkinsci/kubernetes-plugin)

Don't get intimidated by its README, it describes the most complex scenario it's capable of,
but we'll need only the very basic things. An ESP build is in fact one single step, and
then we'll get either the `.bin` artifacts or the error messages, so we won't need pipelines
and all that elaborate groovy wizardry, a single shell-script build step (`make`) will be
just enough.

So we'll have the Jenkins Master and the builder agents, but those agents must be capable of
building an ESP project, from source to binary images, so the agents have to contain the 
[Espressif ESP RTOS SDK](https://docs.espressif.com/projects/esp8266-rtos-sdk/en/latest/get-started/index.html).

NOTE: I intend to make this to support both ESP8266 and ESP32, and considering that Espressif
targets the same goal with their RTOS SDK IDF-style, it seems quite feasible. However, as of now,
it supports only ESP8266, because I wanted to get it working first, and add the features only
after this.

**FIXME: Add ESP32 support**

So we'll need a custom Docker image for these build agents, that contain both the ESP toolchain and
the SDK, and the Jenkins build agent functionality as well.

There is already a [Jenkins JNLP slave image](https://hub.docker.com/r/jenkins/jnlp-slave/), so we'll
use that as base for our image, which we'll store in the Google Container Registry. (We'll use it from
GKE, so that's the nearest docker registry.)

Creating the image is also automated (Ansible again), but we'll discuss both the process and its
requirements in details.

By default the resulting artifacts are collected on the Jenkins Master, but they can be deployed by various Jenkins
plugins as well.

NOTE: At worst I'll just mount a persistent volume (ie. a disk) to that folder on the Master, but
I haven't yet decided what to do exactly with the artifacts, so now they are just piling up on the
Jenkins Masters persistent home volume.

**FIXME: Decide how to handle the artifacts**

Finally, we need to configure Jenkins to actually do all the building stuff.

That's how this project stands now. It can build binaries from a github repo, so we may call this
as a milestone, so it's time to tidy it up, write the docs (like this), and push it to github.


## The playbooks

All major steps (builder image creation, cluster setup, jenkins master setup) are implemented as separate
Ansible playbooks, which share some common parts (roles, variable declarations).

The playbooks (where it makes sense) support at least two tags: `create` and `destroy`. Calling them without tags is the
same as with `create`: they create/update their respective resources.

Calling them with `-t destroy` does the opposite: it demolishes all their resources (usually in the reverse order).

This makes the playbooks a bit harder to read (their second part is the destructor tasks, but some tasks are needed
both for creation and destruction, etc.), but the functionality to *undo* a step is needed anyway.

The project-scope parameters are in `external_vars.yaml`, so most probably that's all you must customize.


## Prerequisites

You need an account to the Google Cloud platform (obviously), you shall create a *project* that will enclose all the
resources and entities we'll create (and separate them from your other things).

From now I'll use the project name `networksandbox-232012`, you should use yours instead.


### A GCP Service Account

Then create a Service Account within this project ([Menu / IAM & Accounts / Service Accounts](https://console.cloud.google.com/iam-admin/serviceaccounts)),
and generate a private key for this account that our mechanisms will use later by clicking the three-dot icon to the
right of the service account, choosing "Create key" and saving the file, like `service_account.json`.

Then you shall authorize this account to perform certain roles in your project:

- Go to [IAM & Accounts / IAM](https://console.cloud.google.com/iam-admin/iam)
- Choose the service account, click its "Edit" on the right
- "Add another role", choose "Kubernetes Engine" / "Kubernetes Engine Admin"
- "Add another role", choose "Service Accounts" / "Service Account User"
- "Add another role", choose "Storage" / "Storage Admin"
- "Add another role", choose "Monitoring" / "Metric Writer"
- Save

Then transfer that `service_account.json` here and tell the gcloud cli to use it:
`gcloud auth activate-service-account --key-file=service_account.json --project networksandbox-232012`

Then you can check its results: `gcloud info`, or actually test if it indeed works: `gcloud container clusters list`

If you got error messages, then something is still wrong, but an empty list is completely normal if you don't have any
clusters created yet. (We'll change that soon :) ...)


### Docker

We'll need to manipulate Docker images, so Docker must be installed, enabled and started.

The docker in the CentOS repo is way too obsolete (as of now: 1.13.whatever), so [install](https://docs.docker.com/install/linux/docker-ce/centos/#install-using-the-repository)
the latest stable (as of now: 19.03.5) from the Docker repo instead.


### OS packages

docker, kubectl

python3-google-auth, python3-openshift, pyton3-dns


### An external static IP address

And perhaps an A record in a registered domain, so the Jenkins Master can be accessible like "https://jenkins.my-domain.com",
and not just via an IP address.

Static addresses can be registered on the Google web console: Menu / VPC Networks / External IP Addresses / Reserve Static Address

Name it like "jenkins", it'll be used only to refer to it from the Ansible playbooks, the actual hostname is a
completely different thing.

The tier of the IP must match the tier of the project, otherwise no part of this project can use it (default: "Premium").

The scope can be either global or regional, and it can't be changed later:

- If we intend to use it for Load Balancers, it must be regional
- If we intend to use it for Ingress Controllers, it must be global

As of now, we use it for a Load Balancer (details later), so set it to REGIONAL.

#### Billing

The GCP platform bills you for reserved addresses when they are **unassigned**  but not if they are assigned to a VM
instance or a Load Balancer or an Ingress Controller.

Being assigned is enough, it doesn't need to be running, so a stopped instance or a Load Balancer of a cluster that
has been scaled down to zero nodes is also free. (I think they just don't want to keep them reserved out of sheer
laziness to release them, which is quite understandible.)


#### DNS

After you reserved an IP, you'll see the actual IP address you got, so if you own a domain, you may add an A record
to that address and name it like "jenkins.your-domain.com".


### A server certificate

If you own a domain and registered a server name for this Jenkins Master, and you don't want your browser to constantly
nag about the site being unverified and insecure and untrusted, etc., you may buy a server certificate for it.

Or if you do this too frequently, just buy a wildcard certificate for your domain and use that for all your servers.
(Though it's somewhat less secure: if one of your servers gets compromised and your private key stolen, then your other
servers can also be impersonated until you replace the certificate with a reissued new one.)


## Creating the builder image

Basically, we take the Jenkins standard builder agent Docker image "jenkins/jnlp-slave", add the ESP toolchain to it,
clone the SDKs into it, set up the paths and environment just according to the SDK docs, and tag and push the result
to an image registry.

`./run.sh 00_create_esp_builder_image.yaml`

Below the hood:

- We are downloading the toolchain tarball only when needed (`roles/download-if-needed`).
- The folder `esp8266-rtos-sdk-image` contains the `sdkconfig.default` and the `Dockerfile`

The rest is quite straightforward, see the contents of `esp8266-rtos-sdk-image/Dockerfile`.


## Creating the cluster

Due to an Ansible limitation (now: 2.9.3) we can't directly customise the node pool (i.e. specify auto-repair,
auto-upgrade) that we create the cluster with, so a small quirk is needed: we create the cluster with a minimal default
pool, create the real pool and add it to the cluster, and finally remove that minimal default pool.

The starting point of the Ansible configuration is `ansible.cfg`, it specifies that the (future) VMs are to be accounted
by the GCP plugin. You don't have to change it, it's just where the avalanche starts.

According to this, the file `inventory.gcp_compute.yaml` tells Ansible the zone and the project in which it should
manage the VMs.

That's what was needed by Ansible, the rest will be needed by our playbooks.

The file `external_vars.yaml` contains all the project- and cluster-specific things that the playbooks
will use. One of its entries, `gcp_cred_file: "service_account.json"` specifies the cloud credentials the playbooks
shall use to perform their tasks. This is the file we have obtained from the GCP web UI, as described above.

After having customized this `external_vars.yaml`, we may actually create the cluster:

`./run.sh 01_cluster.yaml`

This `run.sh` is just a fancy wrapper around `ansible-playbook -i inventory.gcp_compute.yaml whatever.yaml` that 
does some extra log handling I needed frequently enough to hack this script for it. You may as well execute
that `ansible-playbook ...` command directly if that's more convenient for you.


### Checking the cluster

When we want to manage the cluster manually, we'll use the CLI tool `kubectl`, which also needs access to the cluster,
so we must tell it to ask `gcloud` for credentials.

`gcloud container clusters get-credentials --zone=europe-west1-c --project networksandbox-232012 jenkins-cluster`

Then, to check that we can actually access the cluster: `kubectl cluster-info`

NOTE: This is only needed for `kubectl`, as the playbooks access and use the credentials directly.


## Creating the Jenkins Master

For the impatient: `./run.sh 01_jenkins_master.yaml`

NOTE: The GKE Load Balancer needs a few minutes to actually get usable, so even if the playbook finished fine, the
"https://..." URL won't be accessible immediately.

In contrast with the previous steps, here there are quite a lot of details under the hood.

The core of this playbook is a Deployment that creates a pod using the `jenkins/jenkins` image.

As I wanted to keep things as simple as possible, I chose to let Jenkins do the SSL handling of https. (SSL termination on GKE would require another layer: Ingress.)

The Jenkins home directory `/var/jenkins_home` is mounted from a persistent volume, and the SSL keystore is mounted as secrets at `/var/jenkins_secrets/jenkins.jks`.

As the builder agents will report in via JNLP protocol (in contrast with the master connecting to them via SSH), there will be two tcp ports open: 8443 for the usual https web interface and 50000 for jnlp.


### Home directory access

Jenkins stores all its settings, plugin updates, database, etc. in the home of the `jenkins` user, so that home must be mounted from a persistent volume.

Jenkins runs as `jenkins` user (uid=1000), but volume mounts are owned by root:root, so by default the `jenkins` user couldn't access its own home directory.
To resolve this, the mounting *group* must be explicitely specified in template.spec.securityContext.fsGroup.

FIXME: Now the produced binaries are just piling up in the home folder in `/var/jenkins_home/jobs/<project-name>/builds/<build-nr>/archive/`,
so either a deployment step (and infrastructure) will be needed, or at least a persistent volume mount for `.../jobs`.


### Plugin installer timeouts

With the default settings, plugin installation frequently times out.
[Here](https://stackoverflow.com/questions/38100841/jenkins-cannot-download-and-install-plugin-multiple-scm-connection-time-ou)
and [here](https://issues.jenkins-ci.org/browse/JENKINS-36256) it is told that this issue just "does happen", and all
we can do is to wait and try again later.

It seems not to be accurate, because the `CURL_...` environment variables (see the docs of the Jenkins Docker image)
seem just to work fine, all we have to do is to specify them in the Deployment.


### SSL: cert+key issues

According to the docs, Jenkins could handle the usual x509 certificate + private key pair (`--httpsPrivateKey`
and `--httpsCertificate`), but it's rather problematic:

#### PKCS8 vs. PKCS1

The private key must be PKCS1 (`-----BEGIN RSA PRIVATE KEY-----`) and not PKCS8 (`-----BEGIN PRIVATE KEY-----`).

PKCS8 is a more generic format, it's basically an envelope that contains *some* private key and also information
about what sort of private key it is. Like it may contain a PKCS1 RSA private key and the fact that it's an RSA
key (and not of some other algorithm.)

Jenkins (or more precisely Winstone) expects a PKCS1 RSA private key, but it doesn't check the signature (just splits at
`-----`) and if you feed a PKCS8 key to it, you'll get errors like `Caused by: java.io.IOException: DerValue.getBigInteger, not an int 48`

The command `openssl genrsa ...` generates PKCS1 keys, which are suitable for Jenkins, but `openssl req -new -newkey ...`
generates PKCS8, from which the PKCS1 key can be extracted by: `openssl rsa -in my_private.key -out my_private.rsa.key`

Extracting the RSA key from your private key would get you further, but not much, because there's an issue with the
certificates as well:

#### Certificate: no support for chains

Usually you server certificate is signed by some department of a certificate provider, whose department-cert is signed
by their main corporate-cert, which is signed by some root CA.

The clients know (and trust implicitely) only the root CAs, so to make your certificate *verifiable*, all this chain
must be present whenever your server shows it up to a client. So the server must have not just its own certificate, but
all the other intermediary ones as well.

Usually there are two ways to specify this:
- Either there is a separate option for specifying the intermediary CA certificates
- Or is is implicitely assumed that your certificate file contains the whole chain, one after another, in the order of
  their dependence (i.e. the server certificate being the 1st one)

Jenkins chose none of these, it just has no support for *specifying* chained certificates, so if your cert isn't signed
directly by a root CA (it isn't), the it'll still count as unverifiable.

(It's a good thing that all the sources are available on github, so at least I could dig into the issue and find a solid
answer instead of the "it doesn't work for me either"-s. It took half a day, but I just don't like uncovered areas...)

So **the "private key + certificate" support is useful only for self-signed certificates** (which still protect against
traffic sniffing, but not against MITM attacks).


#### Keystores: no PKCS12, only JKS

Don't get me wrong, Jenkins **does** support chained certificates, you just can't specify them with `--httpsCertificate`.

If not cert + private key, then the other way is to use a **keystore**, a container file that may incorporate multiple
private keys and certificates and is protected by some password: see options `--httpsKeyStore` and `--httpsKeyStorePassword`.

They do work, but they support only the Java-specific Java Key Store format, and not the standard PKCS12.

It's sort of a nuisance, as all the non-Java world uses plain private key files (either PKCS1 or PKCS8), but
the Java keystore handler `keytool` has no option for *importing* private keys, only for *generating* them. (Sure, if
anyone else has access to a private key, they can't guarantee its safety, but hey, I'm the user, I've payed for that
darn certificate, so I'd like to keep this decision for myself.)

So either you generate the private key for your certificate by `keytool` and then you won't access it from anywhere
but Java, or you generate it by standard tools (`openssl req -new -newkey ...`), and then `keytool` won't let you add it to
a Java keystore.

At least so it would seem...

Perhaps someone in the ivory towers of the Java world also had a bright glimpse about the actual use cases, because
`keytool` has a feature that, despite all other measures, lets us import private keys: by importing complete keystores.

Having the certificate and the private key, we can import them to a (standard) PKCS12 keystore, and then
import that into a Java keystore:

```
openssl pkcs12 -inkey my_private.key -in my_certificate.chained.crt -export -out my_keystore.p12 -passout "my pkcs12 password"
keytool -importkeystore -srckeystore my_keystore.p12 -srckeypass "my pkcs12 password" -srcstoretype pkcs12 -destkeystore jenkins.jks -destkeypass "my jks password"
```

#### Conclusion

Maybe choosing to handle the SSL by Jenkins wasn't the simpler way after all...

On the other hand, the Ingress Controllers in GKE can only dispatch traffic to NodePort or LoadBalancer service
endpoints (i.e. to ClusterIP **it can't**), so if we had Jenkins listen on plain http and do the SSL termination by an
Ingress Controller, then that plain http port should have a public IP, which IMHO exposes the same set of (hypothetical)
Jenkins vulnerabilities as with exposing its https port.

As we don't use the other benefits of an Ingress Controller (servername- and url-based dispatching, etc.), we wouldn't
gain anything for the extra complexity.

Anyway, these parameters (keystore file name and password) are configured in `external_vars.yaml`, and the settings are
passed in the `JENKINS_OPTS` environment variable in the Deployment.


## Jenkins setup

If all went well, Jenkins is up and running, and waiting for our first login to finish the installation process.

To authenticate this first login, it has generated a random admin password, which was written into its log, so let's
take a look at that log: `kubectl logs -f svc/jenkins-master`

```
Jenkins initial setup is required. An admin user has been created and a password generated.
Please use the following password to proceed to installation:

<nasty random hexdump>

This may also be found at: /var/jenkins_home/secrets/initialAdminPassword
```

If we log in to Jenkins with that, we may install the plugins (the recommended ones will do, although we won't really
need them), create a first admin user, and then we can log in with that account.

And when we try to change anything, there comes the next problem:


### Error messages about invalid crumbs

GKE Load Balancers handle the HTTP headers in a way that confuses Jenkins' default anti-CSRF mechanism, which results
"403 No valid crumb was included in the request" error messages.

To overcome them, set this option:

- Manage Jenkins / Configure Global Security / CSRF Protection / Enable proxy compatibility: [X]

Sort of unfortunate, that you can't do it though the Load Balancer because you'd get this error for that as well, so I
suggest to tunnel the port 8443 of the pod through the Kubernetes management layer:
`kubectl port-forward pod/jenkins-master-<random>  8443:8443`, and then access "https://localhost:8443".


### Configuring the Kubernetes plugin

Install the Kubernetes plugin, if you haven't done so already:

- Manage Jenkins / Manage Plugins / Available / Kubernetes ("This plugin integrates Jenkins with Kubernetes"): [X]

Choose "Install without restart".

Then we have to tell Jenkins *how* to access the Kubernetes infrastructure and *what sort of*
pods it shall spawn to act as build agents.

The important but not fully evident point here is the way Jenkins decides what agents to use/spawn for a given
build step later:

Agents (and Pod Templates) may have "labels" associated to them, that describe their "capabilities".
Later in the build steps we can specify what combination of such "capabilities" are required to perform that given
build step, and Jenkins will choose/spawn the agent accordingly.

- Manage Jenkins / Manage Nodes and Clouds / Configure Clouds / Add a new cloud / Kubernetes:
    - Name: **the-farm**
    - Kubernetes URL: https://kubernetes.default.svc.cluster.local
    - Kubernetes Namespace: default
    - Credentials: **networksandbox-232012** / (key) Add / Jenkins:
        - Domain: Global credentials
        - Kind: Google Service Account from private key
        - Project Name: **networksandbox-232012**
        - JSON Key: [X], File upload: **`service_account.json`**
    - Test connection (should return: Connection test successful)
    - Direct Connection: [X]
    - Connection Timeout: 5
    - Read Timeout: 15
    - Concurrency limit: 10
    - Add Pod Label / Pod Label:
        - Key: role
        - Value: agent
    - Max connections to Kubernetes API: 32
    - Seconds to wait for pod to be running: 600
    - Pod Templates / Add Pod Template:
        - Name: **esp-builder-pod**
        - Pod Template Details:
            - Name: **esp-builder-pod**
            - Namespace: default
            - Labels: **esp-builder**
            - Usage: Only build jobs with label expressions matching this node
            - Containers / Container Template:
                - Name: **jnlp**
                - Docker image: **eu.gcr.io/networksandbox-232012/esp8266-rtos-sdk**
                - Always pull image: [X]
                - Working directory: /home/jenkins/agent
                - Command to run: **<empty>**
                - Arguments to pass to the command: **<empty>**
                - Allocate pseudo TTY: [X]

Most of these settings are generic, the highlighted values are however specific:

- the-farm: Just a name for this "cloud", it's just for you to distinguish it from other such "clouds"
- networksandbox-232012: The name of your GCP project in which all this is happening
- `service_account.json`: The credentials to create the builder pods with
- esp-builder-pod: Name prefix for the agent pods, also used only for making them easily distinguishable.
- jnlp: Now that must be exactly this, because that's built into the "jenkins/jnlp-slave" image as well
- registry/project/esp8266-rtos-sdk: Docker image to use for the builder pods (we'll discuss this in details below)

Now Jenkins is ready for building our ESP projects, we just have to define one!


## Define a project

A "project" here is process whose input is a given branch of a git repo, and whose results are the binary image
files we can transfer to the ESP devices.

Jenkins has the ability to handle very complex processing pipelines, defined in a declarative or in a
programmatic way, google search will dump you a bookshelf-worth of docs about it in no time.

We won't need that. At all.

All the **internal** steps of the build process (like dependency graph handling, compiling, linking,
stripping, etc.) are already taken care of by the SDK and happen in its own domain, all we have to do is
- Provide the ESP toolchain binaries and set the PATH for it (done by our builder image)
- Set the `IDF_PATH` environment variable to the SDK we want to use (also done by the builder image)
- Provide the sources (done by the git plugin of Jenkins)
- Say `make` und watchen das blinkenlichts :D

So we'll create a Project exactly for that:
- A single build step that says `make`, and
- A post-build action that collects the resulting ".bin" files to preserve


The setup:

- New Item / Name: **my-esp-demo** / Freestyle project / OK:
    - Discard old builds: [X]
        - Max # of builds to keep: 2
    - GitHub project: [X]
        - Project url: **`https://github.com/gsimon75-iot/esp_rtos_project_skel`**
        - Restrict where this project can be run: [X]
            - Label Expression: **esp-builder**
    - Source Code Management / Git: [X]
        - Repository URL: **`https://github.com/gsimon75-iot/esp_rtos_project_skel.git`**
    - Build triggers:
        - GitHub hook trigger for GITScm polling: [X]
    - Build / Add build step / Execute shell:
        - Command: make
    - Post-build Actions / Add post-build action / Archive the artifacts:
        - Files to archive: **`build/**/*.bin`**

As you see, the source repo url is given in twice:

Once for the "GitHub project", this goes to the [GitHub plugin](https://github.com/jenkinsci/github-plugin), it's used
later for automatic job triggering and build status reporting, and once for "Source Code Management", this goes to the
Git plugin and tells where to clone the sources from.

You may have also noticed the label "esp-builder": this is the point where the project and the agent are connected.


## TODO

So that's how it is now. As of the future things I have in mind:

- Automatic build triggering after a push to github
- Finetuning Jenkins permissions
- Dealing with the artifacts
- ESP32 support
- Support for collateral goals like building docs from in-code comments
- Etc.
- Stop the feature creep :D

[//]: # ( vim: set sw=4 ts=4 et: )
