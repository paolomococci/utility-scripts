# 🎯 `classify.sh` - A Bash Script for Querying Open Source Decision Models

## 📌 Introduction

`classify.sh` is a Bash script that simplifies interaction with locally installed decision-making models through Ollama.
It supports JSON, CSV and TSV formats for the state file and processes CSV/TSV files line by line, transforming them into JSON objects.

## 📌 Summary

- Input: state file (JSON, CSV, or TSV) and questions file (JSON).
  - Preferred separator: comma (`,`).
  - Supports "nested quotes" (e.g., "Knapsack "Special" Edition").

- Output: a structured JSON response containing probabilities, confidence scores and, for score-type questions, a numeric value.

- Text colors: the script uses red, yellow, magenta and cyan colors for text messages.

- Unicode support is required: this lets us show icons like 🤓, ℹ️, ⚠️ and non-ASCII text. Most recent terminals and editors already have it built-in.

- Key Features:
  - Verbose debugging with `CLASSIFY_VERBOSE`.
  - Configurable Ollama host through `OLLAMA_HOST`.

- Requirements: `cURL`, `jq` (≥ 1.6), a running `Ollama server` (≥ 0.40.5) and `GNU Awk`.

- Helpers:
  - `error`: Prints `red` error messages.
  - `check_consistent_fields`: Checks if all CSV rows have the same number of columns.
  - `validate_csv_structure`: Checks for empty lines and unmatched quotes.
  - `validate_file`: Identifies the file format (JSON, TSV, CSV).
  - `validate_json_array`: Ensures JSON arrays aren't empty.
  - `sanitize_host`: Cleans up the host string (removes protocols, trailing slashes).
  - `extract_headers`: Gets CSV headers.
  - `detect_separator`: Infers the separator (`,`, `;`, `|`, `:`, `\t`).
  - `csv_line_to_json`: Crucial logic for converting a row into a JSON object.
  - `check_model`: Checks if the model exists on the Ollama server.
  - `validate_and_check`: Aggregates all format-specific validations.
  - `check_connection_and_model`: Tests network connectivity and model availability.
  - `resolve_host_and_port`: Parses host/port from arguments or environment variables.
  - `send_request`: The core `curl` call to the Ollama API.

Main Logic: It handles argument parsing, file reading and JSON on an object-by-object basis.

## 📌 Requirements

✅ **cURL**: The command line tool for transferring data using URLs.
✅ **jq**: The script requires the `jq`, version 1.6+, utility to be installed on the system.
✅ **Ollama**: The Ollama, version 0.40.10+, server must be running and accessible.
✅ **GNU Awk**: The pattern scanning, text processing language for Unix-like systems.

If your Ollama server is running on a non-standard IP address or port, set the `OLLAMA_HOST` environment variable to ensure the script can connect to it.

To ensure a correct and trouble-free installation, it's best to rely on the official resources provided by the operating system manufacturer and the software developer.

---

## 📌 Warnings

😊 **The `classify.sh` script is distributed under the MIT license.**

⚠️ **As always, it's a good idea to exercise caution when running any script! Review the script before running it and run it at your own risk.**

👉 **The script `classify.sh` uses `cURL` to establish a connection over the `http` protocol to the `/v1/systemone` endpoint, rather than the standard API. Verify that this endpoint is functioning correctly.**

👉 **The first row of CSV/TSV files must contain the column headers and there must be no empty lines!**

👉 **The script `classify.sh` exits with a non-zero exit code if errors occur. You can check the exit code using the `$?` variable in your shell, as follows: `echo $?`.**

---

## 📌 Supported Formats

### `state_file` (input file)

1. **JSON** `UTF-8 encoded` (e.g., `knapsack.json`)

- Must be a valid `JSON object` (e.g., `{"key": "value"}`).
- Example:

```json
{
  "item_one": "description",
  "item_two": 10,
  "item_three": true
}
```

2. **CSV** `UTF-8 encoded` (e.g., `products.csv`)

- Supports separators: `,` `;` `:` `|`.
- Example (comma separator):

```csv
item_one,item_two,item_three
description,10,true
```

3. **TSV** `UTF-8 encoded` (e.g., `state.tsv`)

- Values are separated by tabs (e.g., `item_one item_two`).
- Example:

```tsv
item_one  item_two  item_three
description  10  true
```

Note that the identifiers in the `state` files were generated using the `uuidgen` command for example purposes.

### `questions_file` (`UTF-8 encoded`)

Must be a valid JSON file (e.g., `questions.json`), such as:

```json
{
  "defective_product": {
    "type": "choice",
    "instructions": "Does the customer report a defect that compromises the normal or safe use of the product?",
    "criteria": {
      "true": "The customer reports a defect that compromises use or safety.",
      "false": "The customer does not report a defect that compromises use or safety."
    }
  },
  "category": {
    "type": "choice",
    "instructions": "What is the main category of the inquiry?",
    "criteria": {
      "defective_product": "The product is broken or defective.",
      "return_exchange": "The customer wants to return or exchange a product that is not described as defective.",
      "information": "The customer is requesting general information.",
      "none": "None of the above."
    }
  },
  "proposed_solution": {
    "type": "choice",
    "instructions": "What is the most appropriate next step based on the available information?",
    "criteria": {
      "request_evidence": "Request photos of the defect and proof of purchase, then evaluate the case.",
      "offer_replacement": "Directly offer a replacement without further verification.",
      "reject": "Reject the request."
    }
  },
  "urgency": {
    "type": "score",
    "instructions": "How urgent is it to handle the request, considering that the defect makes the product unsafe to use?",
    "criteria": [
      "Low: The product is usable and there's no rush.",
      "Medium: The product is usable with some inconvenience.",
      "High: The product should not be used until the issue is resolved."
    ]
  },
  "desired_action": {
    "type": "choice",
    "instructions": "What is the customer's desired action?",
    "criteria": {
      "replacement": "The customer wants a replacement.",
      "refund": "The customer wants a refund.",
      "repair": "The customer wants the product to be repaired.",
      "other": "The customer has not specified a preference."
    }
  }
}
```

## 📌 Known Limitations

To mitigate the risk of exceeding the `ARG_MAX` limit imposed by the Linux kernel on process arguments and environment variables, the script transmits JSON objects individually.
However, each individual object should also be kept to a reasonable size.
The Linux kernel may have a total memory limit for all arguments and environment variables of around 2 MiB.

You can verify this limit using the `getconf` command as follows:

```sh
getconf ARG_MAX
```

---

## 📌 Troubleshooting

- Error 404: Verify that the model name is correct.
- Connection error: Ensure that `OLLAMA_HOST` is accessible and that port 11434 is open.

---

## 📌 Usage

1. **Prepare the script:**

```sh
mkdir -p ~/Workshop/AI/classify/defective_products
cd ~/Workshop/AI/classify/
nano classify.sh
chmod 740 classify.sh
```

2. **Check installed models on Ollama:**

```sh
export OLLAMA_HOST=192.168.XXX.XXX
curl "http://${OLLAMA_HOST}:11434/api/tags" | jq | grep name
```

or:

```sh
curl -s http://${OLLAMA_HOST}:11434/v1/models | jq '.data[].id'
```

3. **Run the script:**

   To get started with the script:

```sh
./classify.sh --version
./classify.sh --help
```

Run Bash in tracing mode:

```sh
bash -x ./classify.sh ./defective_products/knapsack.json model_name ./defective_products/questions.json
```

Before executing each command, it prints the expanded command to the terminal; after variable expansion, substitution and globbing.
This is useful for seeing what a script is doing and finding errors.

_Notes_:

- Replace `192.168.XXX.XXX` with the IP address of the Ollama server.
- Replace `model_name` with the name of the Ollama model you want to use. You can list available models using the commands in the 'Check installed models' section.

---

## 📌 Optional Environment Variables

- **`CLASSIFY_VERBOSE=true`**: Enables verbose mode for debugging.

```sh
CLASSIFY_VERBOSE=true ./classify.sh ./defective_products/knapsack.json model_name ./defective_products/questions.json
```

_Note_: This option only works if the state file is in CSV or TSV format.

## Notes

- **First row of CSV/TSV files**: Must contain the column headers.
- **Error handling**: The script exits with a non-zero exit code if errors occur. You can check the exit code using the `$?` variable in your shell, as follows: `echo $?`.

Now try:

```sh
unset OLLAMA_HOST
CLASSIFY_VERBOSE=true OLLAMA_HOST=192.168.XXX.XXX ./classify.sh ./defective_products/products.csv model_name ./defective_products/questions.json
```

---

## 📌 Helpful Notes for Developers

### example output

```json
{
  "model": ...,
  "answers": {
    "defective_product": {
      "type": "choice",
      "choice": "true",
      "probabilities": {
        "true": 0.9979331268413529,
        "false": 0.0020668731586469457
      },
      "confidence": 0.9958662536827059
    },
    "category": {
      "type": "choice",
      "choice": "defective_product",
      "probabilities": {
        "defective_product": 0.9884443891338253,
        "return_exchange": 0.001418974591306486,
        "information": 0.009802350965654261,
        "none": 0.0003342853092140351
      },
      "confidence": 0.9845925188451004
    },
    "proposed_solution": {
      "type": "choice",
      "choice": "request_evidence",
      "probabilities": {
        "request_evidence": 0.9414441734049498,
        "offer_replacement": 0.016895292466078966,
        "reject": 0.04166053412897121
      },
      "confidence": 0.9121662601074245
    },
    "urgency": {
      "type": "score",
      "score": 1.9831154376619418,
      "legend": {
        "0": "Low: The product is usable and there's no rush.",
        "1": "Medium: The product is usable with some inconvenience.",
        "2": "High: The product should not be used until the issue is resolved."
      },
      "probabilities": {
        "0": 0.008201732027228124,
        "1": 0.0004810982836022484,
        "2": 0.9913171696891697
      },
      "confidence": 0.9746731564929123
    },
    "desired_action": {
      "type": "choice",
      "choice": "replacement",
      "probabilities": {
        "replacement": 0.9929116774951015,
        "refund": 0.001951505858522262,
        "repair": 0.004770138510350132,
        "other": 0.00036667813602606444
      },
      "confidence": 0.9905489033268019
    }
  },
  "usage": {
    "input_tokens": ...,
    "output_tokens": ...
  }
}
```

## 📌 Explanation of Field Meanings

Generic fields:

- **probabilities**: Shows the complete probability distribution. A value `> 0.9` indicates high certainty.
- **confidence**: Can be used as a threshold to decide whether to request further checks or proceed automatically with a proposed solution. A confidence score near 1.0 indicates a high degree of certainty in the model's prediction.
- **input_tokens**: In a local environment, this count primarily serves to:
  - Monitor GPU/CPU usage to optimize performance.
  - Estimate inference duration.
  - Help plan server resource allocation.

Specific fields:

- **defective_product**: Indicates whether the product is defective (`true/false`)
- **category**: The main category of the investigation (e.g., `"defective_product"`, `"return_exchange"`)
- **proposed_solution**: The solution proposed by the model (e.g., `"request_evidence"`, `"offer_replacement"`, `"reject"`)
- **urgency**: Urgency level as a numerical score between 0 and 2:
  - `0`: Low: The product is usable and there's no rush.
  - `1`: Medium: The product is usable with some inconvenience.
  - `2`: High: The product should not be used until the issue is resolved.
    This value can be used to prioritize tasks and trigger different workflows based on the urgency level.
- **desired_action**: The customer's desired action (`"replacement"`, `"refund"`, `"repair"`, `"other"`)

---

## 📌 Useful Notes for Script Formatting

I used the following shell command to format the script, explicitly specifying dialect `bash`:

```sh
shfmt --version
shfmt --help
shfmt --indent 4 --language-dialect bash --diff classify.sh
```

to see the differences that will be applied.

The following command, however, is used for the actual writing:

```sh
shfmt --indent 4 --language-dialect bash --write classify.sh
```

Furthermore, if desired, the script can also be compacted using the following command:

```sh
shfmt --minify --diff classify.sh
```

And then:

```sh
shfmt --minify --write classify.sh
```
