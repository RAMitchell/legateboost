from pathlib import Path

import seaborn as sns
from matplotlib import pyplot as plt
from matplotlib.ticker import FuncFormatter

import cunumeric as cn
import legateboost as lb

sns.set()
plt.rcParams["font.family"] = "serif"

rs = cn.random.RandomState(42)
X = cn.linspace(0, 10, 200)[:, cn.newaxis]
y_true = X[:, 0].copy() + cn.sin(X[:, 0]) * 3
y_true[X.shape[0] // 2 :] += 3.0
y = y_true + rs.normal(0, 0.25, X.shape[0])
params = {
    "n_estimators": 200,
    "learning_rate": 0.5,
    "verbose": True,
    "random_state": 20,
}
eval_result = {}
linear_model = lb.LBRegressor(base_models=(lb.models.Linear(),), **params).fit(
    X, y, eval_set=[(X, y_true)], eval_result=eval_result
)
linear_test_error = cn.sqrt(eval_result["eval-0"]["mse"])
tree_model = lb.LBRegressor(base_models=(lb.models.Tree(max_depth=1),), **params).fit(
    X, y, eval_set=[(X, y_true)], eval_result=eval_result
)
tree_test_error = cn.sqrt(eval_result["eval-0"]["mse"])
krr_model = lb.LBRegressor(base_models=(lb.models.KRR(n_components=20),), **params).fit(
    X, y, eval_set=[(X, y_true)], eval_result=eval_result
)
krr_test_error = cn.sqrt(eval_result["eval-0"]["mse"])


combined_model = lb.LBRegressor(
    base_models=(
        lb.models.KRR(n_components=20),
        lb.models.Linear(),
        lb.models.Tree(max_depth=1),
    ),
    **params
).fit(X, y, eval_set=[(X, y_true)], eval_result=eval_result)
combined_test_error = cn.sqrt(eval_result["eval-0"]["mse"])

# plot
fig, ax = plt.subplots(1, 2, figsize=(12, 6))
plt.gca().xaxis.set_major_formatter(FuncFormatter(lambda x, _: int(x)))
sns.scatterplot(x=X[:, 0], y=y, color=".2", alpha=0.5, label="f(x)+noise", ax=ax[0])
sns.lineplot(x=X[:, 0], y=linear_model.predict(X), label="linear model", ax=ax[0])
sns.lineplot(x=X[:, 0], y=tree_model.predict(X), label="tree model", ax=ax[0])
sns.lineplot(x=X[:, 0], y=krr_model.predict(X), label="krr model", ax=ax[0])
sns.lineplot(x=X[:, 0], y=combined_model.predict(X), label="combined model", ax=ax[0])
ax[0].set_xlabel("X")

sns.lineplot(
    x=range(len(linear_test_error)), y=linear_test_error, label="linear model", ax=ax[1]
)
sns.lineplot(
    x=range(len(linear_test_error)), y=tree_test_error, label="tree model", ax=ax[1]
)
sns.lineplot(
    x=range(len(krr_test_error)),
    y=krr_test_error,
    label="krr model",
    ax=ax[1],
)
sns.lineplot(
    x=range(params["n_estimators"]),
    y=combined_test_error,
    label="combined model",
    ax=ax[1],
)
ax[1].set_xlabel("n_estimators")
ax[1].set_ylabel("test error")
plt.suptitle("Combined model learning")
plt.tight_layout()
image_dir = Path(__file__).parent
plt.savefig(image_dir / "kernel_ridge_regression.png")
