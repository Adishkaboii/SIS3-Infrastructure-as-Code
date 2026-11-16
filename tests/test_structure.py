import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class TemplateRequirements(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = (ROOT / 'templates/application.yaml').read_text()
        cls.registry = (ROOT / 'templates/registry.yaml').read_text()
        cls.network = (ROOT / 'templates/network.yaml').read_text()
        cls.api = (ROOT / 'api/app.py').read_text()

    def test_queue_retry_and_retention(self):
        for required in ('VisibilityTimeout: 70', 'maxReceiveCount: 5',
                         'MessageRetentionPeriod: 1209600', 'MessageRetentionPeriod: 345600'):
            self.assertIn(required, self.app)

    def test_batch_failure_and_concurrency(self):
        for required in ('ReportBatchItemFailures', 'BatchSize: 5', 'MaximumConcurrency: 2'):
            self.assertIn(required, self.app)

    def test_idempotency_and_domain_event(self):
        self.assertIn('attribute_not_exists(orderId)', self.app)
        self.assertIn('OrderPlaced', self.app)
        self.assertIn('OrdersTopic', self.app)

    def test_fargate_roles_alb_and_logs(self):
        for required in ('TaskExecutionRole:', 'TaskRole:', 'TargetType: ip',
                         'AwsvpcConfiguration:', 'LogGroupName:', 'RetentionInDays:',
                         'DeploymentCircuitBreaker:', 'HealthCheckPath: /health'):
            self.assertIn(required, self.app)

    def test_registry_settings(self):
        for required in ('ImageTagMutability: IMMUTABLE', 'ScanOnPush: true', 'LifecyclePolicy:'):
            self.assertIn(required, self.registry)

    def test_network_no_nat(self):
        self.assertIn('AWS::EC2::VPC', self.network)
        self.assertNotIn('AWS::EC2::NatGateway', self.network)

    def test_api_accepts_query_string(self):
        self.assertIn('urlsplit(self.path).path', self.api)


if __name__ == '__main__':
    unittest.main()
