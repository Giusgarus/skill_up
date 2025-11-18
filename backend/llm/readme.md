Before you run the server make sure you have the .env with the api key in the same directory:
```
.\backend\llm\.env
```


run the following command to run the server for the llm:
```
python -m uvicorn gen_ai_response:app --reload --port 8001
```

