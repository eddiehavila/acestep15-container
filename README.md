# acestep15-container
The comfyui AceStep1.5 implementation is not very good and lacking a lot of the functionality so...

we are going to hijack the best and most feature complete github.com/mmartial/ComfyUI-Nvidia-Docker nvidia docker container to run the AceStep1.5 api server, AceStep native WebUI, and the more sane github.com/fspecii/ace-step-ui WebUI


```
git clone https://github.com/eddiehavila/acestep15-container.git

cd acestep15-container

chmod +x ./run/user_script.bash

docker compose --file compose.yaml up
```
 
 
 
 
It will automatically download ***ALL*** the AceStep models (~50GB)



Native AceStep1.5 Gradio WebUI at http://localhost:7860/

github.com/fspecii/ace-step-ui at http://localhost:3000/


