#!/bin/bash

brew services start mongodb-community
python3 create_db.py
pytest -q