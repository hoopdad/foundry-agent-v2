echo "Run me as . ./pysetup.sh to set up the Python environment for the Foundry Agent"
python3 -m venv venv
source venv/bin/activate
python -m pip install -r requirements.txt