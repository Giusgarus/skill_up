Before you run the server make sure you have the .env with the api key in the same directory:
```
.\backend\llm\.env
```


run the following command to run the server for the llm:
```
python -m uvicorn gen_ai_response:app --reload --port 8001
```


#### The Structure of the LLM output 
Now the function returns the following: 
```python
@app.post("/generate-challenge")
async def handle_challenge_request(req: Request, payload: GenerateRequest):
    ...
    return JSONResponse(
        content={
            "challenge_data": challenge_data,
            "challenge_meta": challenge_meta,
        },
        status_code=200
    )
```

So this will be something like this:
```json
    content = {
        "challenge_data": {
            "challenges_count": <int>,
            "challenges_list": [
                {
                    "challenge_title": "Quest Name (Max 20 chars)",
                    "challenge_description": "Specific action instructions. 1-2 sentences.",
                    "duration_minutes": <int>,
                    "difficulty": "<Easy|Medium|Hard>"              
                }
            ],
            "error_message": null // or string if invalid
        }
        "challenge_meta": {
            time_frame_days: <int>,
            preferred_days: [<str>, <str>, ...],
            goal_title: "<str>"
            
        }
    }
```