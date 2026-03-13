#!/bin/bash

docker login
docker tag 1de3778ae422 fiercebrake/arch:1.1.0
docker push fiercebrake/arch:1.1.0
