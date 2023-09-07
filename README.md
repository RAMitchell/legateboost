# LegateBoost

GBM implementation on Legate. The primary goals of LegateBoost is to provide a state-of-the-art distributed GBM implementation on Legate, capable of running on CPUs or GPUs at supercomputer scale.


For developers - see [contributing](contributing.md)

## Example

Run with the legate launcher
```bash
legate example_script.py
```

```python
import cunumeric as cn
import legateboost as lb

X = cn.random.random((1000, 10))
y = cn.random.random(X.shape[0])
model = lb.LBRegressor(verbose=1, n_estimators=100, random_state=0, max_depth=2).fit(
    X, y
)
```

## Features

### Probabilistic regression
Legateboost can learn distributions for continuous data. This is useful in cases where simply predicting the mean does not carry enough information about the training data:

<img src="examples/probabalistic_regression/probabilistic_regression.gif" alt="drawing" width="800"/>

The above example can be found here: [examples/probabilistic_regression](examples/probabalistic_regression/README.md).

### Batch training
Legateboost can train on datasets that do not fit into memory by splitting the dataset into batches and training the model with `partial_fit`.
```python
total_estimators = 100
model = lb.LBRegressor(n_estimators=estimators_per_batch)
for i in range(total_estimators // estimators_per_batch):
    X_batch, y_batch = train_batches[i % n_batches]
    model.partial_fit(
        X_batch,
        y_batch,
    )
```

<img src="examples/batch_training/batch_training.png" alt="drawing" width="600"/>

The above example can be found here: [examples/batch_training](examples/batch_training/README.md).

### Different model types
Legateboost supports tree models, linear models, kernel ridge regression models, custom user models and any combinations of these models.

The following example shows a model combining linear and decision tree base learners.

```python
model = lb.LBRegressor(base_models=(lb.models.Linear(),)*5 + (lb.models.Tree(max_depth=1),)*15, **params).fit(X, y)
```

<img src="examples/linear_model/linear_model.png" alt="drawing" width="800"/>

## Installation

Dependencies:
- cunumeric
- sklearn

From the project directory
```
pip install .
```
